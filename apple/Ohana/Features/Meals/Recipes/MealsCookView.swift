import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cooking a recipe step by step (web: meals/cook/[id], cooking-view.tsx): choose servings and,
/// for a recipe with both, by hand or with the machine; then one step at a time in big type,
/// swiping (or ← →) between them, with the step's ingredients scaled. The screen stays awake
/// on iPhone and iPad while cooking; the step reached is remembered per device.
struct MealsCookView: View {
    let recipeID: String
    var servings: Int?

    init(recipeID: String, servings: Int? = nil) {
        self.recipeID = recipeID
        self.servings = servings
    }

    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<RecipeResolved> = .idle

    var body: some View {
        LoadStateView(state: state, retry: load) { recipe in
            RecipeCookSession(recipe: recipe, initialServings: servings ?? recipe.detail.defaultServings)
        }
        .ohanaBackground(ModuleTint.meals)
        .task(id: recipeID) { await load() }
    }

    private func load() async {
        await LoadState.run($state) {
            RecipeResolved(try await family.api.get("/meals/recipes/\(recipeID)", as: RecipeDetailResponse.self))
        }
    }
}

/// The cook view once the recipe is loaded.
private struct RecipeCookSession: View {
    let recipe: RecipeResolved
    @State private var servings: Int
    @State private var method: RecipeCookMethod?
    @State private var started = false
    @State private var stepIndex = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    init(recipe: RecipeResolved, initialServings: Int) {
        self.recipe = recipe
        _servings = State(initialValue: initialServings)
        let hasManual = !recipe.detail.manualSteps.isEmpty, hasMachine = !recipe.detail.machineSteps.isEmpty
        _method = State(initialValue: hasManual && hasMachine ? nil : hasMachine ? .machine : .manual)
    }

    private var hasBoth: Bool { !recipe.detail.manualSteps.isEmpty && !recipe.detail.machineSteps.isEmpty }
    private var steps: [RecipeStep] { recipe.steps(method ?? .manual) }
    private var progressKey: String { "ohana-cooking-\(recipe.detail.id)-\((method ?? .manual).rawValue)" }

    var body: some View {
        Group {
            if started, !steps.isEmpty {
                stepsView
            } else {
                setup
            }
        }
        .navigationTitle(recipe.detail.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if started {
                ToolbarItem(placement: .primaryAction) { servingsStepper(compact: true) }
                if hasBoth {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Change method", systemImage: "arrow.left.arrow.right") {
                            withAnimation { started = false }
                        }
                        .help("Back to servings and method")
                    }
                }
            }
        }
        .onChange(of: stepIndex) { _, index in
            if started { UserDefaults.standard.set(index, forKey: progressKey) }
        }
        .onChange(of: started) { _, on in keepAwake(on) }
        .onDisappear { keepAwake(false) }
    }

    // MARK: Before starting

    private var setup: some View {
        ScrollView {
            VStack(spacing: 24) {
                RemoteImage(path: recipe.detail.imagePath) { RecipePhotoPlaceholder() }
                    .frame(width: 180, height: 180)
                    .clipShape(.circle)
                    .glassEffect(.regular, in: .circle)
                    .padding(.top, 24)
                Text(recipe.detail.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                VStack(spacing: 16) {
                    HStack {
                        Label("Servings", systemImage: "person.2").font(.headline)
                        Spacer()
                        servingsStepper(compact: false)
                    }
                    if hasBoth {
                        Picker("Method", selection: Binding(get: { method ?? .manual }, set: { method = $0 })) {
                            ForEach(RecipeCookMethod.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .contentCard(cornerRadius: 24, padding: 18)
                .frame(maxWidth: 480)
                if steps.isEmpty {
                    Text("This recipe has no steps yet.").foregroundStyle(.secondary)
                } else {
                    Button {
                        start()
                    } label: {
                        Label("Let’s cook!", systemImage: "frying.pan")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: 360)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .tint(ModuleTint.meals)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    private func start() {
        if method == nil { method = recipe.detail.manualSteps.isEmpty ? .machine : .manual }
        let saved = UserDefaults.standard.object(forKey: progressKey) as? Int
        stepIndex = saved.flatMap { steps.indices.contains($0) ? $0 : nil } ?? 0
        withAnimation { started = true }
    }

    private func servingsStepper(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { servings = max(1, servings - 1) } label: { Image(systemName: "minus") }
                .disabled(servings <= 1)
                .accessibilityLabel("Fewer servings")
            Text(verbatim: "\(servings)")
                .font((compact ? Font.body : .title2).monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .frame(minWidth: compact ? 24 : 36)
                .accessibilityLabel("\(servings) servings")
            Button { servings = min(50, servings + 1) } label: { Image(systemName: "plus") }
                .accessibilityLabel("More servings")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .animation(.snappy, value: servings)
    }

    // MARK: Cooking

    private var stepsView: some View {
        VStack(spacing: 16) {
            progress
            pager
            controls
        }
        .padding()
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            Text("Step \(stepIndex + 1) of \(steps.count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= stepIndex ? AnyShapeStyle(ModuleTint.meals.gradient) : AnyShapeStyle(.quaternary))
                        .frame(height: 6)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation { stepIndex = index } }
                        .accessibilityLabel("Step \(index + 1) of \(steps.count)")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #if os(iOS)
            Text("Swipe left or right to switch steps")
                .font(.caption)
                .foregroundStyle(.tertiary)
            #endif
        }
    }

    @ViewBuilder private var pager: some View {
        #if os(iOS)
        TabView(selection: $stepIndex) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepCard(step).tag(index).padding(.horizontal, 4)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        stepCard(steps[min(stepIndex, steps.count - 1)])
            .id(stepIndex)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 {
                    go(value.translation.width < 0 ? 1 : -1)
                }
            })
        #endif
    }

    private func stepCard(_ step: RecipeStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let program = RecipeProgram.title(of: step.programType) {
                    Label(program, systemImage: "gearshape.2")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ModuleTint.meals)
                }
                if !step.instruction.isEmpty {
                    Text(step.instruction)
                        .font(.system(.title, design: .rounded, weight: .medium))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RecipeStepParams(step: step)
                    .font(.title3)
                let lines = recipe.lines(of: step, servings: servings)
                if !lines.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { line in
                            RecipeIngredientLineView(line: line)
                                .font(.title3)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .glassEffect(.regular.tint(ModuleTint.meals.opacity(0.12)), in: .rect(cornerRadius: 32))
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    go(-1)
                } label: {
                    Label("Back", systemImage: "chevron.left").frame(minWidth: 90)
                }
                .buttonStyle(.glass)
                .disabled(stepIndex == 0)
                Spacer()
                if stepIndex >= steps.count - 1 {
                    Button {
                        UserDefaults.standard.removeObject(forKey: progressKey)
                        keepAwake(false)
                        if isPresented { dismiss() } else { withAnimation { started = false } }
                    } label: {
                        Label("All done!", systemImage: "checkmark").frame(minWidth: 110)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.meals)
                } else {
                    Button {
                        go(1)
                    } label: {
                        HStack {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: 90)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.meals)
                }
            }
            .controlSize(.extraLarge)
        }
    }

    private func go(_ delta: Int) {
        let target = stepIndex + delta
        guard steps.indices.contains(target) else { return }
        withAnimation(.snappy) { stepIndex = target }
    }

    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
