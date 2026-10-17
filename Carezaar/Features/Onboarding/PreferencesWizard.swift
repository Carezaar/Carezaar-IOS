import SwiftUI
import MapKit

/// Shared wizard validation keeps UI messages managed and makes role rules testable.
enum PreferenceValidation {
    static func payProblem(minimum: Int?, maximum: Int?, role: UserRole) -> String? {
        if role == .caregiver, minimum == nil || maximum == nil { return "general_required" }
        if let minimum, let maximum, minimum >= maximum { return "general_salary_min_max" }
        return nil
    }

    static func skillsProblem(role: UserRole, conditions: [Int], specials: [Int], experiences: [Int], roles: [Int], certifications: [Int], languages: [Int]) -> String? {
        let client = role == .client
        let required: [([Int], String)] = [
            (conditions, client ? "signup_form_client_services" : "signup_form_caregiver_carecondition"),
            (specials, client ? "signup_form_client_caregiver_qualities" : "signup_form_caregiver_carespecial"),
            (experiences, client ? "signup_form_client_minimum_experience" : "signup_form_caregiver_experience"),
            (roles, client ? "signup_form_client_preferred_caregiver_role" : "signup_form_caregiver_role")
        ]
        if let missing = required.first(where: { $0.0.isEmpty }) { return missing.1 }
        if languages.isEmpty { return client ? "signup_form_client_preferred_language" : "signup_form_caregiver_languageskill" }
        return nil
    }
}

/// Client care preferences and caregiver skills: the Android 4-step wizard.
///
/// Signup: v2 "Match Prefs - Step 0" intro → steps → Review → Save, which creates the
/// role entity **without a session** (keyed by `user_id`) and then signs in with the
/// held credentials — the account cannot log in until this entity exists (verified
/// live). Edit: the same steps prefilled from the profile, saved with `PUT`.
struct PreferencesWizard: View {
    enum Mode { case signup, edit }
    let role: UserRole
    let mode: Mode

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var started = false
    @State private var step = 0
    @State private var picking = false
    @State private var locationPickerGuidance: String?
    @State private var didInitialize = false
    // Shared selections (client multi-selects everything; caregiver single-selects some).
    @State private var careTypes: [Int] = []
    @State private var conditions: [Int] = []
    @State private var specials: [Int] = []
    @State private var experiences: [Int] = []
    @State private var roles: [Int] = []
    @State private var certifications: [Int] = []
    @State private var languages: [Int] = []
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var commutes: [Int] = []
    @State private var shifts: [Int] = []
    @State private var days: [Int] = []
    @State private var worktypes: [Int] = []
    @State private var genders: [Int] = []
    @State private var salaryMin: Int?
    @State private var salaryMax: Int?

    private var isClient: Bool { role == .client }
    private let totalSteps = 4

    var body: some View {
        Group {
            if !started && mode == .signup {
                intro
            } else {
                wizard
                    .fullScreenCover(isPresented: $picking, onDismiss: { locationPickerGuidance = nil }) {
                        MapLocationPicker(initial: coordinate, unavailableGuidance: locationPickerGuidance) { picked in
                            coordinate = picked
                            locationPickerGuidance = nil; picking = false
                        } onCancel: { locationPickerGuidance = nil; picking = false }
                    }
            }
        }
        // F1: the phone's location is never filled in by itself; it is used only
        // when the person taps My Location on the map.
        .task {
            guard !didInitialize else { return }
            didInitialize = true
            await prefill()
        }
    }

    // MARK: intro (v2 "Match Prefs - Step 0")

    private var intro: some View {
        FigmaScreen(key: "v2-65-19934", binder: SceneBinder(
            handle: { node in
                if node.isBackButton { router.pop(); return true }
                if node.isPrimaryButton || node.actionTarget != nil { started = true; return true }
                return false
            },
            text: { node in
                guard !isClient else { return nil }
                if node.name == "Title" { return loc.t("signup_form_caregiver_match_title", "Find Your Ideal Matches") }
                if node.name == "Description" { return loc.t("signup_form_caregiver_match_description", "") }
                return nil
            },
            // The caregiver frame (715:11684) shows its own skills illustration.
            isHidden: { node in !isClient && ["101:11970", "101:11969", "101:11971"].contains(node.id) }),
            overlays: isClient ? [] : [
                SceneOverlay(x: 94, y: 110, width: 224, height: 238) {
                    if let url = SourceStore.assetURL("mobile-match-skills-illustration.png"), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                },
            ],
            fitHeight: true)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: wizard

    private var wizard: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                Stepper4(step: step + 1, total: totalSteps, label: loc.t("step_wizard_step", "Step").uppercased())
                    .id("wizard-top")
                Text(title).font(Theme.Typography.heading(24)).multilineTextAlignment(.center)
                Text(subtitle).font(Theme.Typography.body(15)).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
                VStack(spacing: Theme.Spacing.m) { stepBody }
            }
            .padding(.horizontal, Theme.Spacing.m).padding(.bottom, 130)
        }
        // The steps share this scroll view: each new step (Continue or Back) opens at
        // its top, as on Android, not at the previous step's scroll position.
        .onChange(of: step) { _, _ in proxy.scrollTo("wizard-top", anchor: .top) }
        }
        .scrollDismissesKeyboard(.interactively)
        .bottomAction {
            VStack(spacing: 8) {
                PrimaryButton(title: step == totalSteps - 1 ? loc.t("general_save", "Save") : loc.t("signup_form_client_continue", "Continue")) { advance() }
                HStack(spacing: 6) {
                    AppIcon(name: "ic_info_circle", size: 18, tint: Theme.Palette.primary)
                    Text(loc.t("signup_form_client_create_account_description", "You can change all of this later."))
                        .font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 10).background(.white)
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { back() } label: { AppIcon(name: "ic_arrow_backward", size: 22, tint: .black) }
                    .accessibilityLabel("Back")
            }
        }
    }

    private var title: String {
        switch (step, isClient) {
        case (0, true): return loc.t("signup_form_client_select_care_type", "Select your care type")
        case (0, false): return loc.t("signup_form_caregiver_supported_client_types_title", "Which Client Types Do You Support?")
        case (1, true): return loc.t("signup_form_client_tell_us_about_needs", "Tell us about your needs")
        case (1, false): return loc.t("signup_form_caregiver_skill_title", "Tell us about your skills")
        case (2, true): return loc.t("signup_form_client_schedule_preferences", "Your schedule & preferences")
        case (2, false): return loc.t("signup_form_caregiver_schedule_title", "Your schedule & preferences")
        case (_, true): return loc.t("signup_form_client_review", "Review Your Preferences")
        default: return loc.t("signup_form_caregiver_review_title", "Review your skills and availability")
        }
    }

    private var subtitle: String {
        switch (step, isClient) {
        case (0, true): return loc.t("signup_form_client_select_care_type_description", "")
        case (0, false): return loc.t("signup_form_caregiver_supported_client_types_description", "")
        case (1, true): return loc.t("signup_form_client_needs_description", "")
        case (1, false): return loc.t("signup_form_caregiver_skill_description", "")
        case (2, true): return loc.t("signup_form_client_schedule_preferences_description", "")
        case (2, false): return loc.t("signup_form_caregiver_schedule_description", "")
        case (_, true): return loc.t("signup_form_client_review_description", "")
        default: return loc.t("signup_form_caregiver_review_description", "")
        }
    }

    private var hint: String { loc.t("signup_form_client_select_all_that_apply", "Select all that apply") }

    private var languageSection: some View {
        ChipSection(title: loc.t(isClient ? "signup_form_client_preferred_language" : "signup_form_caregiver_languageskill", ""),
                    hint: hint, items: baseData.items(.languageskills), selection: $languages, icons: true)
    }

    @ViewBuilder private var stepBody: some View {
        switch step {
        case 0:
            CareTypeCards(items: baseData.items(.clienttypes), selection: $careTypes, multiple: !isClient)
        case 1:
            ChipSection(title: loc.t(isClient ? "signup_form_client_services" : "signup_form_caregiver_carecondition", ""),
                        hint: hint, items: baseData.items(.careconditions), selection: $conditions, icons: true, tiles: true)
            ChipSection(title: loc.t(isClient ? "signup_form_client_caregiver_qualities" : "signup_form_caregiver_carespecial", ""),
                        hint: hint, items: baseData.items(.carespecials), selection: $specials, icons: true)
            // Figma order: the client frame lists languages after qualities, the
            // caregiver frame after the role.
            if isClient { languageSection }
            ChipSection(title: loc.t(isClient ? "signup_form_client_minimum_experience" : "signup_form_caregiver_experience", ""),
                        hint: isClient ? hint : nil, items: baseData.items(.experiences), selection: $experiences, single: !isClient)
            ChipSection(title: loc.t(isClient ? "signup_form_client_preferred_caregiver_role" : "signup_form_caregiver_role", ""),
                        hint: isClient ? hint : nil, items: baseData.items(.roles), selection: $roles, single: !isClient)
            if !isClient { languageSection }
            ChipSection(title: loc.t(isClient ? "signup_form_client_required_certifications" : "signup_form_caregiver_certification", ""),
                        hint: hint, items: baseData.items(.certifications), selection: $certifications)
        case 2:
            LocationRow(coordinate: coordinate, hint: loc.t("signup_form_client_location_hint", "Tap to select location")) {
                locationPickerGuidance = nil
                picking = true
            }
            ChipSection(title: loc.t(isClient ? "signup_form_client_max_commute" : "signup_form_caregiver_commute", ""),
                        hint: isClient ? hint : nil, items: baseData.items(.commutes), selection: $commutes, single: !isClient)
            ChipSection(title: loc.t(isClient ? "signup_form_client_preferred_shifts" : "signup_form_caregiver_shift", ""),
                        hint: hint, items: baseData.items(.shifts), selection: $shifts, icons: true)
            ChipSection(title: loc.t(isClient ? "signup_form_client_care_days" : "signup_form_caregiver_careday", ""),
                        hint: hint, items: baseData.items(.caredays), selection: $days)
            ChipSection(title: loc.t(isClient ? "signup_form_client_work_type" : "signup_form_caregiver_worktype", ""),
                        hint: isClient ? hint : nil, items: baseData.items(.worktypes), selection: $worktypes, single: !isClient)
            if isClient {
                ChipSection(title: loc.t("signup_form_client_gender_preference", ""), hint: hint,
                            items: baseData.items(.genders), selection: $genders, icons: true)
            }
            SalaryRangeField(minimum: $salaryMin, maximum: $salaryMax)
        default:
            reviewCard
        }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            reviewRow(loc.t("client_details_client_type", "Client Type"), .clienttypes, careTypes)
            reviewRow(loc.t("caregiver_details_provided_care_types", "Care types"), .careconditions, conditions)
            reviewRow(loc.t("caregiver_details_special_qualities", "Qualities"), .carespecials, specials)
            reviewRow(loc.t("caregiver_details_experience", "Experience"), .experiences, experiences)
            reviewRow(loc.t("caregiver_details_role", "Role"), .roles, roles)
            reviewRow(loc.t("caregiver_details_certifications", "Certifications"), .certifications, certifications)
            reviewRow(loc.t("caregiver_details_spoken_languages", "Languages"), .languageskills, languages)
            reviewText(loc.t("signup_form_client_location", "Location"),
                       coordinate.map { String(format: "%.6f , %.6f", $0.latitude, $0.longitude) } ?? "—")
            reviewRow(loc.t("signup_form_client_max_commute", "Max Commute"), .commutes, commutes)
            reviewRow(loc.t("signup_form_client_preferred_shifts", "Preferred Shifts"), .shifts, shifts)
            reviewRow(loc.t("signup_form_client_care_days", "Care Days"), .caredays, days)
            reviewRow(loc.t("signup_form_client_work_type", "Work Type"), .worktypes, worktypes)
            if isClient { reviewRow(loc.t("signup_form_client_gender_preference", "Gender"), .genders, genders) }
            reviewText(loc.t("signup_form_client_pay_rate", "Pay Rate"),
                       "\(loc.t("signup_form_client_minimum", "Minimum")): $\(salaryMin.map(String.init) ?? "—")   \(loc.t("signup_form_client_maximum", "Maximum")): $\(salaryMax.map(String.init) ?? "—")")
        }
        .padding(.horizontal, 16)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Palette.separator))
    }

    private func reviewRow(_ title: String, _ table: BaseTable, _ ids: [Int]) -> some View {
        reviewText(title, ids.compactMap { id in baseData.items(table).first { $0.id == id } }.map { loc.label($0) }.joined(separator: " · "))
    }

    private func reviewText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Typography.title(15)).foregroundStyle(Color(hex: 0x1B4F8F))
            Text(value.isEmpty ? "—" : value).font(Theme.Typography.body(14))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xCFE0F5)).frame(height: 1) }
    }

    // MARK: navigation + validation

    private func back() {
        if step > 0 { step -= 1 }
        else if mode == .signup { started = false }
        else { router.pop() }
    }

    private func need(_ values: [Int], _ slug: String) -> String? {
        values.isEmpty ? loc.t("general_select_one", "You must select at least one item in the \"{PROPERTY}\" section.")
            .replacingOccurrences(of: "{PROPERTY}", with: loc.t(slug, slug)) : nil
    }

    private var problem: String? {
        switch step {
        case 0: return need(careTypes, "client_details_client_type")
        case 1:
            if let slug = PreferenceValidation.skillsProblem(role: role, conditions: conditions, specials: specials, experiences: experiences, roles: roles, certifications: certifications, languages: languages) {
                return need([], slug)
            }
            return nil
        case 2:
            // F3: continuing without a location names what is missing.
            if LocationProvider.initialMapCoordinate(coordinate) == nil {
                return loc.t("general_location_required", "Please select a location to continue.")
            }
            if let p = need(commutes, isClient ? "signup_form_client_max_commute" : "signup_form_caregiver_commute")
                ?? need(shifts, isClient ? "signup_form_client_preferred_shifts" : "signup_form_caregiver_shift")
                ?? need(days, isClient ? "signup_form_client_care_days" : "signup_form_caregiver_careday")
                ?? need(worktypes, isClient ? "signup_form_client_work_type" : "signup_form_caregiver_worktype")
                ?? (isClient ? need(genders, "signup_form_client_gender_preference") : nil) { return p }
            if let slug = PreferenceValidation.payProblem(minimum: salaryMin, maximum: salaryMax, role: role) {
                if slug == "general_required" { return loc.t(slug, "This field is required.") }
                return loc.t(slug, "The minimum pay rate must be lower than the maximum.")
            }
            return nil
        default: return nil
        }
    }

    private func advance() {
        if let problem { feedback.toast(problem); return }
        if step < totalSteps - 1 { step += 1 } else { save() }
    }

    // MARK: data

    private func prefill() async {
        guard mode == .edit, careTypes.isEmpty else { return }
        do {
            if isClient {
                let p = try await feedback.run(loc.t("loading_profile_get", "Getting profile")) { try await ClientService().profile() }
                careTypes = p.clienttypeId.map { [$0] } ?? []; conditions = p.careconditionIds; specials = p.carespecialIds
                experiences = p.experienceIds; roles = p.roleIds; certifications = p.certificationIds; languages = p.languageskillIds
                commutes = p.commuteIds; shifts = p.shiftIds; days = p.caredayIds; worktypes = p.worktypeIds; genders = p.genderIds
                salaryMin = p.salaryMin; salaryMax = p.salaryMax
                if let lat = p.lat, let lng = p.lng,
                   let saved = LocationProvider.initialMapCoordinate(.init(latitude: lat, longitude: lng)) {
                    coordinate = saved
                }
            } else {
                let p = try await feedback.run(loc.t("loading_profile_get", "Getting profile")) { try await CaregiverService().profile() }
                careTypes = p.clienttypeIds; conditions = p.careconditionIds; specials = p.carespecialIds
                experiences = p.experienceId.map { [$0] } ?? []; roles = p.roleId.map { [$0] } ?? []
                certifications = p.certificationIds; languages = p.languageskillIds
                commutes = p.commuteId.map { [$0] } ?? []; shifts = p.shiftIds; days = p.caredayIds
                worktypes = p.worktypeId.map { [$0] } ?? []; salaryMin = p.salaryMin; salaryMax = p.salaryMax
                if let lat = p.lat, let lng = p.lng,
                   let saved = LocationProvider.initialMapCoordinate(.init(latitude: lat, longitude: lng)) {
                    coordinate = saved
                }
            }
        } catch { feedback.toast(Feedback.message(error)) }
    }

    private func save() {
        guard let coordinate = LocationProvider.initialMapCoordinate(coordinate) else {
            // F3: say what is missing instead of opening the map.
            feedback.toast(loc.t("general_location_required", "Please select a location to continue."))
            return
        }
        Task {
            do {
                if isClient {
                    let prefs = ClientPreferences(
                        clienttypeId: careTypes.first ?? 0, lat: coordinate.latitude, lng: coordinate.longitude,
                        salaryMin: salaryMin, salaryMax: salaryMax, careconditionIds: conditions, caredayIds: days,
                        carespecialIds: specials, certificationIds: certifications, commuteIds: commutes,
                        experienceIds: experiences, genderIds: genders, languageskillIds: languages,
                        roleIds: roles, shiftIds: shifts, worktypeIds: worktypes)
                    if mode == .signup, !signUp.entityCreated {
                        _ = try await feedback.run(loc.t("loading_client_signup", "Signing up care needer")) {
                            try await ClientService().create(userId: signUp.userId ?? "", preferences: prefs)
                        }
                        signUp.entityCreated = true
                    } else if mode == .edit {
                        _ = try await feedback.run(loc.t("loading_profile_set", "Updating profile")) { try await ClientService().updateProfile(prefs) }
                    }
                } else {
                    let skills = CaregiverSkills(
                        commuteId: commutes.first ?? 0, experienceId: experiences.first ?? 0, roleId: roles.first ?? 0,
                        worktypeId: worktypes.first ?? 0, lat: coordinate.latitude, lng: coordinate.longitude,
                        salaryMin: salaryMin ?? 0, salaryMax: salaryMax ?? 0, careconditionIds: conditions,
                        caredayIds: days, carespecialIds: specials, certificationIds: certifications,
                        clienttypeIds: careTypes, languageskillIds: languages, shiftIds: shifts)
                    if mode == .signup, !signUp.entityCreated {
                        _ = try await feedback.run(loc.t("loading_caregiver_signup", "Signing up caregiver")) {
                            try await CaregiverService().create(userId: signUp.userId ?? "", skills: skills)
                        }
                        signUp.entityCreated = true
                    } else if mode == .edit {
                        _ = try await feedback.run(loc.t("loading_profile_set", "Updating profile")) { try await CaregiverService().updateProfile(skills) }
                    }
                }
                if mode == .signup {
                    // Only now can the account sign in.
                    try await feedback.run(loc.t("loading_auth_login", "Signing in")) {
                        try await session.signIn(email: signUp.email, password: signUp.password)
                    }
                    signUp.reset()
                } else {
                    router.pop()
                }
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }
}

// MARK: - Components

private struct Stepper4: View {
    let step: Int, total: Int, label: String
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(1...total, id: \.self) { n in
                    ZStack {
                        Circle().fill(n <= step ? Color(hex: 0x1B4F8F) : Color(hex: 0xC8DAF2)).frame(width: 34, height: 34)
                        if n < step { AppIcon(name: "ic_check", size: 16, tint: .white) }
                        else { Text("\(n)").font(Theme.Typography.control(15)).foregroundStyle(n == step ? .white : Color(hex: 0x2A3A52)) }
                    }
                    if n < total { Rectangle().fill(n < step ? Color(hex: 0x1B4F8F) : Color(hex: 0xC8DAF2)).frame(height: 3) }
                }
            }
            .frame(maxWidth: 340)
            Text("\(label) \(step)").font(Theme.Typography.control(14)).foregroundStyle(Color(hex: 0x1B4F8F))
                .padding(.horizontal, 14).padding(.vertical, 5).background(Color(hex: 0xD9E7F7), in: Capsule())
        }
        .padding(.top, 8)
        .accessibilityElement().accessibilityLabel("\(label) \(step) of \(total)")
    }
}

/// Android client-type art → description slug under each care type.
private let careTypeDescriptions: [String: String] = [
    "client_pregnancy": "signup_form_client_birth_postpartum_description",
    "client_child": "signup_form_client_child_care_description",
    "client_senior": "signup_form_client_senior_care_description",
    "client_adult": "signup_form_client_adult_care_description",
]

struct CareTypeCards: View {
    let items: [BaseItem]
    @Binding var selection: [Int]
    var multiple = false
    @EnvironmentObject private var loc: Localization

    var body: some View {
        VStack(spacing: 12) {
            ForEach(items) { item in
                let on = selection.contains(item.id)
                Button {
                    if multiple { if on { selection.removeAll { $0 == item.id } } else { selection.append(item.id) } }
                    else { selection = [item.id] }
                } label: {
                    HStack(spacing: 14) {
                        AppIcon(name: item.icon, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.label(item)).font(Theme.Typography.title(16)).foregroundStyle(.black)
                            if let slug = item.icon.flatMap({ careTypeDescriptions[$0] }) {
                                Text(loc.t(slug, "")).font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer()
                        AppIcon(name: on ? "ic_radiobutton_on" : "ic_radiobutton_off", size: 22,
                                tint: on ? Theme.Palette.primary : Theme.Palette.textSecondary)
                    }
                    .padding(16)
                    .background(on ? Theme.Palette.clientPanel : .white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Theme.Palette.primary : Theme.Palette.separator, lineWidth: 1.5))
                }
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

struct ChipSection: View {
    let title: String
    var hint: String?
    let items: [BaseItem]
    @Binding var selection: [Int]
    var icons = false
    var single = false
    /// The services grid of the Figma frames: four icon tiles per row.
    var tiles = false
    @EnvironmentObject private var loc: Localization

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.Typography.title(16))
                if let hint { Text(hint).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.textSecondary) }
            }
            if tiles {
                // A plain grid, not a lazy one: nested in the step's scroll content, a lazy
                // grid exposed only some tiles to VoiceOver (on a 4.7" phone, only the
                // last), and a dozen tiles gain nothing from laziness.
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 4)), id: \.self) { start in
                        GridRow {
                            ForEach(items[start..<min(start + 4, items.count)]) { item in tile(item) }
                            // Empty cells keep a short last row on the same 4 columns.
                            ForEach(0..<(4 - min(4, items.count - start)), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            } else {
                FlowLayout(spacing: 10) {
                    ForEach(items) { item in
                        chip(item) { on in
                            HStack(spacing: 8) {
                                if icons, item.icon != nil {
                                    AppIcon(name: item.icon, size: 20, tint: item.icon?.hasPrefix("ic_flag") == true ? nil : (on ? Theme.Palette.primary : Theme.Palette.textSecondary))
                                } else {
                                    AppIcon(name: single ? (on ? "ic_radiobutton_on" : "ic_radiobutton_off") : (on ? "ic_checkbox_on" : "ic_checkbox_off"),
                                            size: 18, tint: on ? Theme.Palette.primary : Theme.Palette.textSecondary)
                                }
                                Text(loc.label(item)).font(Theme.Typography.body(14)).foregroundStyle(on ? Color(hex: 0x1B4F8F) : .black)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .shadow(color: Color(red: 16/255, green: 40/255, blue: 80/255).opacity(0.10), radius: 5, y: 2)
    }

    private func tile(_ item: BaseItem) -> some View {
        chip(item) { on in
            VStack(spacing: 6) {
                AppIcon(name: item.icon, size: 28, tint: on ? Theme.Palette.primary : Theme.Palette.textSecondary)
                Text(loc.label(item)).font(Theme.Typography.caption(11)).multilineTextAlignment(.center)
                    .foregroundStyle(on ? Color(hex: 0x1B4F8F) : .black)
                    .lineLimit(2).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2).padding(.top, 12)
            // Equal tiles, whatever the label length, so rows line up.
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .top)
        }
    }

    private func chip<Label: View>(_ item: BaseItem, @ViewBuilder label: (Bool) -> Label) -> some View {
        let on = selection.contains(item.id)
        return Button {
            if single { selection = [item.id] }
            else if on { selection.removeAll { $0 == item.id } } else { selection.append(item.id) }
        } label: {
            label(on)
                .background(on ? Color(hex: 0xE7F1FF) : .white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.Palette.primary : Color(hex: 0xC9D6E6), lineWidth: 1.3))
        }
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

private struct LocationRow: View {
    let coordinate: CLLocationCoordinate2D?
    let hint: String
    let action: () -> Void
    @EnvironmentObject private var loc: Localization
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("signup_form_client_location", "Location")).font(Theme.Typography.title(16))
            Button(action: action) {
                HStack(spacing: 10) {
                    AppIcon(name: "ic_distance", size: 24, tint: Theme.Palette.primary)
                    Text(coordinate.map { String(format: "%.6f , %.6f", $0.latitude, $0.longitude) } ?? hint)
                        .font(Theme.Typography.body(14)).foregroundStyle(coordinate == nil ? Theme.Palette.textSecondary : .black)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    AppIcon(name: "ic_chevron_forward", size: 18, tint: Theme.Palette.textSecondary)
                }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Color(hex: 0xC9CED6)))
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .shadow(color: Color(red: 16/255, green: 40/255, blue: 80/255).opacity(0.10), radius: 5, y: 2)
    }
}

/// Full-screen map with a fixed centre crosshair, a my-location button and Confirm,
/// matching the Android location picker.
struct MapLocationPicker: View {
    let initial: CLLocationCoordinate2D?
    let unavailableGuidance: String?
    let onConfirm: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var loc: Localization
    @StateObject private var location = LocationProvider()
    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var manuallyPositioned = false
    @State private var requestedPhoneLocation = false
    @State private var permissionNote: String?

    /// F1: with no location chosen the map opens on the whole country (contiguous
    /// USA), as the Android and web apps do (web: 39.8283, -98.5795 at zoom 4).
    static let countryRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
                                                  span: MKCoordinateSpan(latitudeDelta: 28, longitudeDelta: 62))

    init(initial: CLLocationCoordinate2D?, unavailableGuidance: String? = nil,
         onConfirm: @escaping (CLLocationCoordinate2D) -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial; self.unavailableGuidance = unavailableGuidance
        self.onConfirm = onConfirm; self.onCancel = onCancel
        let start = LocationProvider.initialMapCoordinate(initial)
        _center = State(initialValue: start)
        _position = State(initialValue: start.map {
            .region(MKCoordinateRegion(center: $0, latitudinalMeters: 3_000, longitudinalMeters: 3_000))
        } ?? .region(Self.countryRegion))
    }

    var body: some View {
        ZStack {
            Map(position: $position)
                .onMapCameraChange(frequency: .continuous) { context in
                    // MapKit's automatic framing is not a selected location.
                    if position.positionedByUser {
                        center = LocationProvider.initialMapCoordinate(context.region.center)
                        manuallyPositioned = true
                        #if DEBUG
                        location.qaManualMapSelectionOccurred(context.region.center)
                        #endif
                    }
                }
                .ignoresSafeArea()
            Image(systemName: "plus").font(.system(size: 36, weight: .ultraLight)).allowsHitTesting(false)
            VStack {
                HStack {
                    Button(action: onCancel) { AppIcon(name: "ic_arrow_backward", size: 22, tint: .black) }
                        .frame(width: 42, height: 42).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.separator))
                        .accessibilityLabel("Back")
                    Spacer()
                    Text(loc.t("general_location", "Location")).font(Theme.Typography.title(18))
                    Spacer()
                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)).padding(14)
                Spacer()
                if let permissionNote {
                    Text(permissionNote)
                        .font(Theme.Typography.body(14)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("location-permission-denied")
                        .onTapGesture { self.permissionNote = nil }
                }
                HStack {
                    Spacer()
                    Button {
                        // F2: access refused: say so instead of appearing not to work.
                        if location.isDenied { showPermissionDenied(); return }
                        requestedPhoneLocation = true
                        manuallyPositioned = false
                        location.request()
                    } label: { AppIcon(name: "ic_my_location", size: 26, tint: Theme.Palette.primary) }
                        .frame(width: 56, height: 56).background(.white, in: Circle()).shadow(radius: 4)
                        .accessibilityLabel("My location")
                }
                .padding(.horizontal, 20)
                PrimaryButton(title: center == nil ? loc.t("general_continue", "Continue") : loc.t("general_confirm", "Confirm")) {
                    if let center { onConfirm(center) } else { onCancel() }
                }
                    .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        // F1: the phone's position is used only after My Location is tapped.
        .onReceive(location.$coordinate) { coordinate in
            guard let coordinate, !manuallyPositioned, requestedPhoneLocation else { return }
            center = coordinate
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000))
        }
        // F2: the person refused the system prompt raised by My Location.
        // `$status` emits before the property changes, so the emitted value is used:
        // reading `location.isDenied` here would still see the old status.
        .onReceive(location.$status) { status in
            if requestedPhoneLocation, status == .denied || status == .restricted {
                requestedPhoneLocation = false; showPermissionDenied()
            }
        }
        .onDisappear { location.cancel() }
    }

    private func showPermissionDenied() {
        let note = loc.t("general_location_permission_denied", "Allow location access to use your current location.")
        permissionNote = note
        UIAccessibility.post(notification: .announcement, argument: note)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if permissionNote == note { permissionNote = nil }
        }
    }
}
