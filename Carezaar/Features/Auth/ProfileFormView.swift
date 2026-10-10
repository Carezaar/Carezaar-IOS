import SwiftUI
import PhotosUI
import AVFoundation

/// "Tell us about yourself".
///
/// Signup: `users/profile` multipart **without** a session, keyed by email, then on
/// to the role's preference wizard. Edit (from Profile): same endpoint, signed in,
/// prefilled from `auth/info`. The photo is optional, as in the Android app.
struct ProfileFormView: View {
    enum Mode { case signup, edit }
    let mode: Mode

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var signUp: SignUpFlow
    @EnvironmentObject private var baseData: BaseDataStore
    @EnvironmentObject private var loc: Localization
    @EnvironmentObject private var feedback: Feedback

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var bio = ""
    @State private var genderId: Int?
    @State private var dateOfBirth: Date?
    @State private var photoData: Data?
    @State private var remotePhoto: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var choosingSource = false
    /// A freshly picked photo waiting for the square crop.
    @State private var cropping: CropItem?
    @State private var showingGallery = false
    @State private var showingCamera = false
    @State private var cameraDenied = false
    @State private var choosingGender = false
    @State private var errors: [String: String] = [:]
    @State private var loaded = false

    private let userService = UserService()
    private var adultLimit: Date { Calendar.current.date(byAdding: .year, value: -18, to: .now) ?? .now }
    private var valid: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
            && genderId != nil && (dateOfBirth.map { $0 <= adultLimit } ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("signup_form_client_tell_us_about_yourself", "Tell us about yourself")).font(Theme.Typography.heading(24))
                    Text(loc.t("signup_form_client_about_yourself_description", "This helps us match you with the right caregiver."))
                        .font(Theme.Typography.body(15)).foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.top, Theme.Spacing.s)

                photoSection

                AdaptiveStack(spacing: 14) {
                    LabeledField(label: loc.t("profile_edit_first_name", "First name") + " *",
                                 placeholder: loc.t("profile_edit_enter_first_name", "Enter your first name"),
                                 text: $firstName, contentType: .givenName, error: errors["first_name"])
                    LabeledField(label: loc.t("profile_edit_last_name", "Last name") + " *",
                                 placeholder: loc.t("profile_edit_enter_last_name", "Enter your last name"),
                                 text: $lastName, contentType: .familyName, error: errors["last_name"])
                }

                AdaptiveStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(loc.t("profile_edit_gender", "What is your gender?") + " *")
                            .font(Theme.Typography.body()).foregroundStyle(Theme.Palette.textSecondary)
                        Button { choosingGender = true } label: {
                            HStack {
                                AppIcon(name: gender?.icon, size: 22, tint: Theme.Palette.textSecondary)
                                Text(gender.map { loc.label($0) } ?? loc.t("profile_edit_gender_placeholder", "Select your gender"))
                                    .foregroundStyle(gender == nil ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                                Spacer()
                                AppIcon(name: "ic_chevron_down", size: 18, tint: Theme.Palette.textSecondary)
                            }
                            .font(Theme.Typography.control(15)).padding(.horizontal, 14).frame(minHeight: 52)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.Palette.separator))
                        }
                        if let e = errors["gender_id"] { Text(e).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.error) }
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(loc.t("profile_edit_date_of_birth", "Date of birth") + " *")
                            .font(Theme.Typography.body()).foregroundStyle(Theme.Palette.textSecondary)
                        DatePicker("", selection: Binding(get: { dateOfBirth ?? adultLimit }, set: { dateOfBirth = $0 }),
                                   in: ...adultLimit, displayedComponents: .date)
                            .labelsHidden().frame(minHeight: 52)
                            .accessibilityLabel(loc.t("profile_edit_date_of_birth", "Date of birth"))
                        Text(errors["date_of_birth"] ?? loc.t("profile_edit_age_requirement", "You must be 18 years or older."))
                            .font(Theme.Typography.caption())
                            .foregroundStyle(errors["date_of_birth"] == nil ? Theme.Palette.textSecondary : Theme.Palette.error)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(loc.t("profile_edit_bio", "Bio (optional)")).font(Theme.Typography.body()).foregroundStyle(Theme.Palette.textSecondary)
                    TextField(loc.t("profile_edit_bio_placeholder", "Tell us a little about yourself."), text: $bio, axis: .vertical)
                        .lineLimit(4...8).font(Theme.Typography.control(15)).padding(14)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.Palette.separator))
                }
            }
            .padding(.horizontal, Theme.Spacing.m).padding(.bottom, 100)
        }
        .bottomAction {
            PrimaryButton(title: mode == .signup ? loc.t("general_continue", "Continue") : loc.t("profile_save", "Save"),
                          isEnabled: valid) { submit() }
                .padding(.horizontal, Theme.Spacing.m).padding(.vertical, 10).background(.white)
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("", isPresented: $choosingSource) {
            Button(loc.t("general_camera", "Camera")) { Task { await openCamera() } }
            Button(loc.t("general_gallery", "Gallery")) { showingGallery = true }
        }
        .photosPicker(isPresented: $showingGallery, selection: $pickerItem, matching: .images)
        .alert(loc.t("camera_permission_denied_title", "Camera access is off"), isPresented: $cameraDenied) {
            Button(loc.t("navigation_drawer_settings", "Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button(loc.t("general_gallery", "Gallery")) { showingGallery = true }
            Button(loc.t("general_cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("camera_permission_denied_message",
                       "To take a profile picture, allow camera access for Carezaar in Settings. You can also choose a photo from your gallery."))
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in cropping = UIImage(data: data).map(CropItem.init) }.ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                cropping = UIImage(data: data).map(CropItem.init)
            }
        }
        .fullScreenCover(item: $cropping) { item in
            PhotoCropper(image: item.image) { data in
                photoData = data; cropping = nil
            } onCancel: { cropping = nil; pickerItem = nil }
        }
        .sheet(isPresented: $choosingGender) {
            VStack(spacing: 12) {
                ForEach(baseData.items(.genders)) { item in
                    Button { genderId = item.id; choosingGender = false } label: {
                        HStack(spacing: 14) {
                            AppIcon(name: item.icon, size: 26, tint: .black)
                            Text(loc.label(item)).font(Theme.Typography.control(17))
                            Spacer()
                        }
                        .padding(16)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(item.id == genderId ? Theme.Palette.primary : Theme.Palette.separator))
                    }
                    .foregroundStyle(.black)
                }
            }
            .padding(20)
            .presentationDetents([.height(200)])
        }
        .task { await prefill() }
    }

    private var gender: BaseItem? { baseData.items(.genders).first { $0.id == genderId } }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(loc.t("profile_edit_profile_picture", "Profile Picture (optional)")).font(Theme.Typography.title(16))
            HStack(spacing: 18) {
                Group {
                    if let photoData, let image = UIImage(data: photoData) { Image(uiImage: image).resizable().scaledToFill() }
                    else if let remotePhoto { AsyncImage(url: URL(string: remotePhoto)) { $0.resizable().scaledToFill() } placeholder: { Color(hex: 0xEEF1F5) } }
                    else {
                        ZStack {
                            Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5])).foregroundStyle(Color(hex: 0xB9BFC8))
                            AppIcon(name: "ic_camera", size: 44, tint: Theme.Palette.textSecondary)
                        }
                    }
                }
                .frame(width: 112, height: 112).clipShape(Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc.t("profile_edit_upload_profile_picture", "Upload a profile picture")).font(Theme.Typography.title(15))
                    Text(loc.t("profile_edit_profile_picture_description", "This helps caregivers get to know you."))
                        .font(Theme.Typography.caption(13)).foregroundStyle(Theme.Palette.textSecondary)
                    if photoData != nil || remotePhoto != nil {
                        Button { photoData = nil; remotePhoto = nil; pickerItem = nil } label: {
                            Label(loc.t("profile_edit_remove_photo", "Remove Photo"), systemImage: "xmark")
                                .font(Theme.Typography.control(14)).foregroundStyle(Theme.Palette.error)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.error))
                        }
                    } else {
                        Button { choosingSource = true } label: {
                            HStack(spacing: 6) {
                                AppIcon(name: "ic_upload", size: 18, tint: Theme.Palette.primary)
                                Text(loc.t("profile_edit_upload_photo", "Upload Photo"))
                            }
                            .font(Theme.Typography.control(14)).foregroundStyle(Theme.Palette.primaryText)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.primary))
                        }
                    }
                }
            }
        }
    }

    /// The photo part for `users/profile`. The server treats a save without one as
    /// "remove the photo" (BE-15), so an unchanged photo is downloaded and sent back;
    /// only Remove Photo leaves it out.
    private func photoPart() async throws -> MultipartFile? {
        if let photoData { return MultipartFile(name: "photo", filename: "profile.jpg", mimeType: "image/jpeg", data: photoData) }
        guard mode == .edit, let remotePhoto, let url = URL(string: remotePhoto) else { return nil }
        let data = try await UserService.download(url)
        let name = url.lastPathComponent.isEmpty ? "profile.jpg" : url.lastPathComponent
        let mime = switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
        return MultipartFile(name: "photo", filename: name, mimeType: mime, data: data)
    }

    private func prefill() async {
        guard mode == .edit, !loaded else { return }
        loaded = true
        _ = try? await feedback.run(loc.t("loading_auth_info", "Getting user information")) { await session.refreshUser() }
        guard let user = session.state.user else { return }
        firstName = user.firstName ?? ""; lastName = user.lastName ?? ""; bio = user.bio ?? ""
        genderId = user.genderId; remotePhoto = user.photo
        if let raw = user.dateOfBirth {
            let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; f.locale = Locale(identifier: "en_US_POSIX")
            dateOfBirth = f.date(from: raw)
        }
    }

    private func submit() {
        var next: [String: String] = [:]
        let required = loc.t("general_required", "This field is required.")
        if firstName.trimmingCharacters(in: .whitespaces).isEmpty { next["first_name"] = required }
        if lastName.trimmingCharacters(in: .whitespaces).isEmpty { next["last_name"] = required }
        if genderId == nil { next["gender_id"] = required }
        if dateOfBirth == nil { next["date_of_birth"] = required }
        errors = next
        guard next.isEmpty else { return }
        let email = mode == .signup ? signUp.email : (session.state.user?.email ?? "")
        Task {
            do {
                let label = mode == .signup ? loc.t("loading_auth_register", "Registering") : loc.t("loading_profile_set", "Updating profile")
                let saved = try await feedback.run(label) {
                    try await userService.setProfile(
                        email: email, genderId: genderId,
                        firstName: firstName.trimmingCharacters(in: .whitespaces),
                        lastName: lastName.trimmingCharacters(in: .whitespaces),
                        bio: bio.isEmpty ? nil : bio, dateOfBirth: dateOfBirth,
                        photo: try await photoPart(),
                        anonymous: mode == .signup)
                }
                if mode == .signup {
                    signUp.userId = saved.id
                    router.push(signUp.role == .client ? .signUpFormClient : .signUpFormCaregiver)
                } else {
                    await session.refreshUser()
                    router.pop()
                }
            } catch let error as APIError {
                if case .validation(_, let fields) = error, !fields.isEmpty { errors = fields.compactMapValues(\.first) }
                else if mode == .edit, error.isServiceFault {
                    feedback.toast(Feedback.unavailable(loc.t("profile_edit_title", "Edit profile")))
                } else { feedback.toast(Feedback.message(error)) }
            } catch { feedback.toast(Feedback.message(error)) }
        }
    }
}

/// Camera capture, for the "Camera" choice Android offers alongside the gallery.
extension ProfileFormView {
    /// Asks for camera access the first time; when it was refused (or is restricted),
    /// explains how to turn it on and offers the gallery instead of an empty camera.
    /// Devices without a camera (the Simulator) open the photo library, as before.
    @MainActor func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { showingCamera = true; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showingCamera = true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true } else { cameraDenied = true }
        default: cameraDenied = true
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.cameraDevice = .front
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) { parent.onImage(data) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct CropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
