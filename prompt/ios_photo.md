# Nhiệm vụ: Sửa để private image trên iOS thực sự dùng bytes gốc (không qua ImageUtils.processImage), cho cả photo-library và camera

## Bối cảnh — root cause đã xác định (không cần điều tra lại)

`processThenSendImage(image: UIImage)` tại `bitchat/ViewModels/ChatMediaTransferCoordinator.swift:141` gọi `ImageUtils.processImage(image)` (resize 448px, nén JPEG xuống ~45KB) **vô điều kiện cho mọi ảnh**, trước khi nhánh private/public (`:180`, `:182`) kịp quyết định gì. Nhánh private gọi đúng `prepareOriginalImagePacket(from:)`, nhưng `sourceURL` lúc đó đã là file đã bị nén — nên toàn bộ pipeline byte-identical/Noise/reassembly phía sau (đúng, đã có test khóa) vẫn nhận input sai từ đầu.

Đường đi hiện tại (đã audit đầy đủ, có trích dẫn):
- `bitchat/Views/ContentComposerView.swift:230` — set `imagePickerSourceType`.
- `bitchat/Views/Image Viewers/ImagePickerView.swift:18` — tạo `UIImagePickerController` (dùng cho cả camera lẫn photo library).
- `bitchat/Views/Image Viewers/ImagePickerView.swift:46` — lấy `info[.originalImage] as? UIImage` (đã decode qua UIKit, không phải file gốc trong Photos).
- `bitchat/Views/ContentView.swift:178`, `bitchat/Views/ContentSheetViews.swift:112` → `ConversationUIModel.swift:141` → `ChatViewModel+PrivateChat.swift:122` → `ChatMediaTransferCoordinator.swift:141`.
- `bitchat/Features/media/ImageUtils.swift:76-116` — nơi resize/nén thật sự xảy ra.
- `bitchat/ViewModels/ChatMediaPreparation.swift:67` — `copyOriginalImage(at:)` chỉ copy đúng bytes của file được đưa vào, không khôi phục được bytes gốc nếu input đã bị nén từ trước.

Chưa tìm thấy `PHPickerViewController`/`PHImageManager`/`loadFileRepresentation` trong codebase — app hiện chỉ dùng `UIImagePickerController`.

## Quyết định kiến trúc (đã chọn, không cần hỏi lại)

- **Photo library + private chat**: chuyển sang `PHPickerViewController` + `itemProvider.loadFileRepresentation`/`loadInPlaceFileRepresentation` để lấy thẳng bytes file gốc trong Photos, không qua `UIImage` bước nào. Đây là cách duy nhất đạt byte-identical thật với ảnh HEIC gốc.
- **Photo library + public chat**: hành vi nén giữ nguyên như hiện tại (không đổi) — chỉ cần đảm bảo dù đổi cơ chế lấy ảnh, path public vẫn đưa file qua đúng `ImageUtils.processImage` như trước.
- **Camera (cả private và public)**: không có "file gốc" nào khác ngoài những gì `UIImagePickerController` giao qua `info[.originalImage]` — giữ nguyên `UIImagePickerController` cho camera. Nhưng với **camera + private**, không được resize/nén thêm xuống 448px/45KB nữa — dùng thẳng ảnh picker giao (encode ở chất lượng cao nhất hợp lý, không chủ động downsize). Với camera + public, giữ nguyên hành vi nén hiện tại.
- Đây không phải byte-identical-với-file-ngoài (không có file ngoài để so với camera), nên tiêu chí cho camera+private là "không downsize/nén thêm so với những gì OS giao", không phải SHA-256 khớp với một asset khác.

## Trước khi code — xác nhận lại (Think Before Coding, phạm vi hẹp)

- Xác nhận chữ ký hiện tại của `ImageUtils.processImage` — tài liệu kiến trúc cũ từng ghi có overload `processImage(at: URL, ...)` ngoài `processImage(_ image: UIImage, ...)`. Xác nhận còn đúng không, dùng overload nào cho public+library.
- Xác nhận `ContentComposerView`/nơi trigger picker có biết ngữ cảnh đang soạn cho chat nào (private hay public) tại thời điểm hiển thị picker hay không — việc này quyết định có thể luôn dùng `PHPickerViewController` cho mọi lựa chọn từ thư viện ảnh (rồi để nhánh xử lý sẵn có ở `ChatMediaTransferCoordinator` quyết định nén hay không), hay bắt buộc phải biết trước private/public mới chọn đúng picker component. Ưu tiên phương án không cần biết trước ngữ cảnh (đơn giản hơn) nếu khả thi.
- Nếu phát hiện việc đổi picker ảnh hưởng tới thứ khác ngoài phạm vi (ví dụ multi-select ảnh, đính kèm video nếu có) — dừng lại, nêu rõ, hỏi trước khi mở rộng.

## Tiêu chí thành công

1. Private chat, chọn ảnh từ photo library (kể cả HEIC): bytes gửi đi khớp SHA-256 tuyệt đối với file gốc trong Photos.
2. Private chat, chụp bằng camera: ảnh không còn bị resize-448px/nén-45KB; vẫn qua đúng pipeline Noise-chunk hiện có.
3. Public chat (cả camera lẫn library): hành vi nén không đổi so với trước khi sửa.
4. **Test tích hợp mới** (đây là phần quan trọng nhất, vì test cũ không bắt được bug vừa xảy ra): viết test gọi qua đúng entry point UI-facing (`processThenSendImage` hoặc hàm tương đương sau khi sửa), không gọi thẳng `prepareOriginalImagePacket`, và assert: với input mô phỏng "ảnh từ thư viện, gửi private", `ImageUtils.processImage` KHÔNG được gọi, và bytes cuối cùng khớp input ban đầu. Test cũ (byte-identical ở tầng chunk/Noise, reject oversized, duplicate chunk, panic wipe) vẫn phải xanh nguyên.
5. `swift test && just build` xanh.

## Ràng buộc

- Không đụng logic chunking/Noise/reassembly đã có (đã đúng và có test khóa) — chỉ sửa từ điểm lấy ảnh tới điểm gọi `prepareOriginalImagePacket`/`ImageUtils.processImage`.
- Không đổi hành vi public path.
- Nếu cần thêm entitlement/permission mới cho `PHPickerViewController` (thường thì PHPicker KHÔNG cần thêm Photos permission, khác với `PHImageManager` trực tiếp) — xác nhận trong lúc code, đừng giả định; nếu cần đụng vào `bitchat/bitchat.entitlements` (file đang dirty ngoài phạm vi từ đầu dự án này) — dừng lại, hỏi trước khi sửa file đó.

## Sau khi xong

Chạy `swift test && just build`. Báo cáo: (a) file nào đã sửa, (b) xác nhận PHPicker không cần thêm permission (hay có, và đã xử lý thế nào), (c) kết quả test integration mới, (d) nhắc lại rằng bytes byte-identical với Photos asset vẫn cần xác nhận thêm một lần nữa qua log SHA-256 trên thiết bị thật trước khi coi là production-verified.
