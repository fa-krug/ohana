import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cooking a recipe step by step (web: meals/cook/[id], cooking-view.tsx): choose servings and,
/// for a recipe with both, by hand or with the machine; then one step at a time in big type,
/// swiping (or ← →) between them, with the step's ingredients scaled. Always presented over
/// everything (`cookPresentation`), so it has its own Close. The screen stays awake on iPhone
/// and iPad while it's shown; the step reached is remembered per device. Durations in a step
/// ("simmer for 20 minutes", `StepDurations`) start a timer (`CookTimers`: a bar here, a Live
/// Activity, a notification when it's done).
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
    @State private var timerStarts = 0
    private let timers = CookTimers.shared
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
            timersBar
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
        .sensoryFeedback(.start, trigger: timerStarts)
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
                stepCard(step, index: index).tag(index).padding(.horizontal, 4)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        stepCard(steps[min(stepIndex, steps.count - 1)], index: min(stepIndex, steps.count - 1))
            .id(stepIndex)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 50 {
                    go(value.translation.width < 0 ? 1 : -1)
                }
            })
        #endif
    }

    private func stepCard(_ step: RecipeStep, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let program = RecipeProgram.title(of: step.programType) {
                    Label(program, systemImage: "gearshape.2")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ModuleTint.meals)
                }
                if !step.instruction.isEmpty {
                    let durations = StepDurations.find(in: step.instruction)
                    Text(StepDurations.linked(step.instruction, durations: durations))
                        .font(.system(.title, design: .rounded, weight: .medium))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(ModuleTint.meals)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let found = StepDurations.index(of: url), durations.indices.contains(found) else {
                                return .systemAction
                            }
                            startTimer(step, index: index, duration: found, seconds: durations[found].seconds)
                            return .handled
                        })
                        .accessibilityHint(durations.isEmpty ? Text(verbatim: "") : Text("Durations start a timer"))
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

    // MARK: Timers

    private func startTimer(_ step: RecipeStep, index: Int, duration: Int, seconds: Int) {
        withAnimation(.snappy) {
            _ = timers.start(source:"\(recipe.detail.id)/\(step.id)/\(duration)", recipeID: recipe.detail.id,
                             recipeTitle: recipe.detail.title, stepID: step.id,
                             stepLabel: String(localized: "Step \(index + 1)"), instruction: step.instruction,
                             seconds: seconds)
        }
        timerStarts += 1
    }

    /// The timers, soonest first: running ones count down, finished ones ring until dismissed.
    /// Tapping one shows its step.
    @ViewBuilder private var timersBar: some View {
        let all = timers.sorted
        if !all.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(all) { timerChip($0) }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func timerChip(_ timer: CookTimer) -> some View {
        let done = timer.isDone(at: timers.now)
        let title = timer.recipeID == recipe.detail.id ? timer.stepLabel : "\(timer.recipeTitle) · \(timer.stepLabel)"
        return HStack(spacing: 10) {
            Button {
                show(timer)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: done ? "bell.fill" : "timer")
                        .foregroundStyle(ModuleTint.meals)
                        .symbolEffect(.wiggle, options: .repeating, isActive: done)
                    Text(verbatim: title)
                        .lineLimit(1)
                    if done {
                        Text("Done")
                    } else {
                        Text(timerInterval: timer.startedAt...timer.endsAt, countsDown: true)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the step")
            Button {
                withAnimation(.snappy) { timers.remove(timer.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? Text("Dismiss timer") : Text("Stop timer"))
        }
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(Color.cardBackground)
                .overlay { Capsule().fill(ModuleTint.meals.opacity(done ? 0.3 : 0.12)) }
        }
    }

    private func show(_ timer: CookTimer) {
        guard timer.recipeID == recipe.detail.id, let index = steps.firstIndex(where: { $0.id == timer.stepID }) else { return }
        withAnimation(.snappy) { stepIndex = index }
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
