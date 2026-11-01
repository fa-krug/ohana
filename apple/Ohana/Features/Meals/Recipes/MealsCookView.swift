import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cooking a recipe step by step (web: meals/cook/[id], cooking-view.tsx): choose servings and,
/// for a recipe with both, by hand or with the machine; then one step at a time in big type,
/// swiping (or ← →) between them, with the step's ingredients scaled. Always presented over
/// everything (`cookPresentation`), so it has its own Close. The screen stays awake on iPhone
/// and iPad while it's shown; the step reached is remembered per device.
struct MealsCookView: View {
    let recipeID: String
    var servings: Int?

    init(recipeID: String, servings: Int? = nil) {
        self.recipeID = recipeID
        self.servings = servings
    }

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<RecipeResolved> = .idle

    var body: some View {
        LoadStateView(state: state, retry: load) { recipe in
            RecipeCookSession(recipe: recipe, initialServings: servings ?? recipe.detail.defaultServings)
        }
        .ohanaBackground(ModuleTint.meals)
        .task(id: recipeID) { await load() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { keepAwake(true) }
        .onDisappear { keepAwake(false) }
    }

    private func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private func load() async {
        // The recipe's page keeps the same copy, so a recipe opened once cooks offline too.
        await LoadState.run($state, MealsRecipeDetailView.request(family.api, recipeID: recipeID), RecipeResolved.init)
    }
}

/// The cook view once the recipe is loaded.
private struct RecipeCookSession: View {
    let recipe: RecipeResolved
    @State private var servings: Int
    @State private var method: RecipeCookMethod?
    @State private var started = false
    @State private var stepIndex = 0
    @FocusState private var pagerFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var photoSize: CGFloat = 180

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
            if started {
                ToolbarItem(placement: .primaryAction) { servingsStepper }
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
        .onChange(of: started) { _, on in pagerFocused = on }
    }

    // MARK: Before starting

    private var setup: some View {
        ScrollView {
            VStack(spacing: 24) {
                RemoteImage(path: recipe.detail.imagePath) { RecipePhotoPlaceholder() }
                    .frame(width: min(photoSize, 280), height: min(photoSize, 280))
                    .clipShape(.circle)
                    .accessibilityHidden(true)
                    .padding(.top, 24)
                Text(recipe.detail.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 16) {
                    Stepper(value: $servings, in: 1...50) {
                        Label {
                            Text("Servings: \(servings)")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        } icon: {
                            Image(systemName: "person.2")
                        }
                        .font(.headline)
                    }
                    .animation(.snappy, value: servings)
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
                    .buttonStyle(.borderedProminent)
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

    /// The servings while cooking, in the toolbar: − count +.
    private var servingsStepper: some View {
        HStack(spacing: 8) {
            Button { servings = max(1, servings - 1) } label: { Image(systemName: "minus") }
                .disabled(servings <= 1)
                .accessibilityLabel("Fewer servings")
            Text(verbatim: "\(servings)")
                .font(.body.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .accessibilityLabel("\(servings) servings")
            Button { servings = min(50, servings + 1) } label: { Image(systemName: "plus") }
                .accessibilityLabel("More servings")
        }
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
        // ← and → page through the steps from a hardware keyboard.
        .focusable()
        .focused($pagerFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onAppear { pagerFocused = true }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Text("Step \(stepIndex + 1) of \(steps.count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            // One adjustable element for VoiceOver (swipe up or down to change the step); each
            // segment takes taps a hit target high.
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= stepIndex ? AnyShapeStyle(ModuleTint.meals.gradient) : AnyShapeStyle(.quaternary))
                        .frame(height: 6)
                        #if os(iOS)
                        .padding(.vertical, 19)
                        #else
                        .padding(.vertical, 6)
                        #endif
                        .contentShape(.rect)
                        .onTapGesture { withAnimation { stepIndex = index } }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progress")
            .accessibilityValue(Text("Step \(stepIndex + 1) of \(steps.count)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: go(1)
                case .decrement: go(-1)
                @unknown default: break
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
        .contentCard(cornerRadius: 32, padding: 0, tint: ModuleTint.meals)
        .clipShape(.rect(cornerRadius: 32))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                go(-1)
            } label: {
                Label("Back", systemImage: "chevron.left").frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .disabled(stepIndex == 0)
            Spacer()
            if stepIndex >= steps.count - 1 {
                Button {
                    UserDefaults.standard.removeObject(forKey: progressKey)
                    dismiss()
                } label: {
                    Label("All done!", systemImage: "checkmark").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.extraLarge)
        .tint(ModuleTint.meals)
    }

    private func go(_ delta: Int) {
        let target = stepIndex + delta
        guard steps.indices.contains(target) else { return }
        withAnimation(.snappy) { stepIndex = target }
    }
}
