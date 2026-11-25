import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true

    private static let english: [(heading: String, body: String)] = [
        ("Data stays on your device",
         "Meward works offline. Photos, watermark text and text recognized in an image are processed on your device. Meward has no accounts, ads or analytics and does not collect personal data or transmit your edits to a server."),
        ("Photos and camera",
         "The system photo picker gives Meward only the photo you select. Tapping the camera requests camera access. A photo taken in Meward is used for editing. The app does not save an unedited camera original to Photos."),
        ("Saving and sharing",
         "Save requests permission to add an edited copy to Photos. Share opens the system share sheet. You decide which app or person receives the copy. Any transfer by that app, or syncing by iCloud Photos, follows your own settings."),
        ("Storage and deletion",
         "Meward creates temporary export files on the device. Copies you save stay in Photos until you delete them there. You can change camera and photo permissions in Settings. Meward has no server-side copy to retain."),
        ("Contact",
         "For privacy questions, email liyufeiat010@gmail.com. Contacting support is optional. If you email us, we use the information you send to answer your request. You can ask us to delete that correspondence.")
    ]

    private static let simplifiedChinese: [(heading: String, body: String)] = [
        ("数据在本机处理",
         "Meward 可以完全离线使用。照片、水印文字和从图片中识别出的文字都在你的设备上处理。Meward 无需注册，没有广告或行为统计，不收集个人数据，也不会将编辑内容发送到服务器。"),
        ("照片和相机",
         "系统选图器只会将你主动选择的照片交给 Meward。点击拍照时，App 才会申请相机权限。拍下的照片用于本次编辑，App 不会把未经处理的原片另存到相册。"),
        ("保存和分享",
         "点击保存时，Meward 会申请将编辑好的副本添加到相册。点击分享时会打开系统分享菜单，由你选择接收的 App 或联系人。接收方 App 的传输和 iCloud 照片同步取决于你自己的设置。"),
        ("存储和删除",
         "Meward 在设备上创建临时导出文件。你主动保存的副本会保留在相册，可以在相册中删除。你可以在系统设置中更改相机和照片权限。Meward 的服务器不留存照片副本。"),
        ("联系开发者",
         "如果有隐私问题，可自愿发送邮件至 liyufeiat010@gmail.com。我们只使用你主动提供的信息来回复这次咨询；你可以要求删除相应邮件。")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Language", selection: $chinese) {
                        Text(verbatim: "English").tag(false)
                        Text(verbatim: "中文").tag(true)
                    }
                    .pickerStyle(.segmented)
                    ForEach(chinese ? Self.simplifiedChinese : Self.english, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: section.heading).font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: section.body).font(.body).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(chinese ? "隐私政策" : "Privacy policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(chinese ? "完成" : "Done") { dismiss() }
                }
            }
        }
    }
}
