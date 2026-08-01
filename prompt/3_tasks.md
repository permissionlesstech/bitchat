# Nhiệm vụ: 3 hạng mục follow-up sau task "private image original-quality + E2EE" — làm theo 3 phase tách biệt

## Lưu ý phạm vi

Đây là 3 việc **độc lập với nhau**, nên coi mỗi phase là một đơn vị commit/PR riêng, không trộn lẫn. Sau mỗi phase, dừng lại trình bày kết quả trước khi sang phase tiếp theo — đừng làm liền một mạch cả 3 rồi mới báo cáo. Thứ tự ưu tiên: A (bảo mật) → B (tính năng nhỏ, rõ ràng) → C (UI/UX, cần nhiều quyết định thiết kế nhất).

**Không nằm trong phạm vi prompt này**: test tay 2–3 thiết bị thật với BLE — việc đó không thể tự động hóa, runbook (`TESTING_HARDWARE_VERIFICATION.md`) đã có sẵn từ trước, vẫn là việc con người làm riêng.

---

## Phase A — Panic-wipe hardening cho việc xóa media chạy `Task.detached`

### Bối cảnh
`ChatViewModel.swift` (~dòng 1282–1306) có block "Delete ALL media files" chạy trong `Task.detached` khi panic wipe được trigger. Đây là code có từ trước dự án private-image (không phải do các thay đổi gần đây gây ra), nhưng ảnh hưởng trực tiếp tới đúng loại dữ liệu nhạy cảm mà dự án private-image vừa bảo vệ (ảnh gốc còn EXIF/GPS ở `images/outgoing`, `images/incoming`, thư mục staging PHPicker). Vì là async, không có gì đảm bảo nó chạy xong trước khi process bị kill — đúng kịch bản panic wipe được sinh ra để đối phó (ai đó ép người dùng thoát app ngay sau khi bấm wipe).

### Trước khi code — điều tra, kèm trích dẫn
1. Đọc chính xác block "Delete ALL media files" hiện tại — xác nhận nó dùng `Task.detached` thô, hay đã có cơ chế bảo vệ nào (background task assertion, v.v.) mà báo cáo trước đó có thể đã bỏ sót.
2. App có target cả iOS lẫn macOS (`bitchat (iOS)`/`bitchat (macOS)` scheme). Hai nền tảng có mô hình suspend/kill khác nhau — iOS có thể suspend app khi background, macOS thường chỉ kill khi user chủ động quit hoặc logout/shutdown. Điều tra: có API portable cho cả 2 nền tảng để "xin thêm thời gian hoàn tất tác vụ trước khi bị suspend/terminate" không (ví dụ `ProcessInfo.performExpiringActivity`, hoặc cặp `UIApplication.beginBackgroundTask` cho iOS + xử lý `applicationShouldTerminate`/tương đương cho macOS)? Trả lời bằng dẫn chứng, đừng đoán API còn hỗ trợ hay không nếu chưa kiểm tra.
3. Cân nhắc và trình bày trade-off giữa 2 hướng trước khi chọn:
   - Bọc `Task.detached` hiện tại bằng cơ chế "xin thêm thời gian" ở bước 2, giữ async.
   - Làm đồng bộ (blocking) riêng cho đúng nhánh panic wipe — chấp nhận UI khựng một chút, ưu tiên chắc chắn xóa xong trước khi trả quyền điều khiển lại cho hệ thống.

### Tiêu chí thành công
- Có cơ chế đảm bảo (không phải "hy vọng") việc xóa `images/outgoing`, `images/incoming`, và staging PHPicker hoàn tất trong một khung thời gian có giới hạn rõ, ngay cả khi app bị background/kill ngay sau khi panic wipe được trigger.
- Test mô phỏng: trigger panic wipe, giả lập app bị background/task bị cancel ngay sau đó, xác nhận file vẫn bị xóa (hoặc ít nhất việc xóa đã bắt đầu và được bảo vệ, tùy theo hướng đã chọn ở bước 3).
- Toàn bộ test hiện có (1637 test) vẫn xanh.
- Không đụng `bitchat.entitlements` (file dirty ngoài phạm vi từ đầu dự án) trừ khi hướng đã chọn ở bước 3 thật sự cần entitlement mới — nếu vậy, dừng lại và hỏi trước khi sửa file đó.

**Dừng lại ở đây, trình bày kết quả Phase A, chờ xác nhận trước khi sang Phase B.**

---

## Phase B — "Original over mesh" opt-in cho ảnh gửi public/broadcast

### Bối cảnh
Hiện public/broadcast image luôn đi qua `ImageUtils.processImage` (nén JPEG, đúng thiết kế, không đổi). Cần thêm lựa chọn thủ công để người dùng chủ động gửi bản gốc cho public khi họ muốn, có cảnh báo rõ.

### Điểm cần xác nhận trước khi code
- Public file transfer (`MessageType.fileTransfer`, broadcast) **đã có** `resolvedTransferId`/throttle riêng qua `bleMaxConcurrentTransfers` từ trước (khác với private, không cần cơ chế chunk-qua-Noise mới xây cho private, vì broadcast không mã hóa theo từng peer). Với ảnh gốc public trong giới hạn `maxPayloadBytes = 1 MiB`, xác nhận: có thể tái dùng thẳng cơ chế `fileTransfer` hiện có (không cần dựng lại kiểu chunk 60 KiB như private) hay không — nếu đúng, đây là cách đơn giản hơn nhiều so với việc nhân bản lại toàn bộ hạ tầng Noise-chunk cho public. Trả lời bằng code, không giả định.
- Public path cần dùng bytes gốc thật (không qua `ImageUtils.processImage`) khi người dùng bật "Original" — có thể tái dùng đúng cơ chế PHPicker + `loadFileRepresentation` đã xây cho private ở vòng trước (đã có staging + cleanup + panic-wipe coverage), chỉ khác điểm đến (`prepareImagePacket` variant không nén, thay vì `prepareOriginalImagePacket` riêng cho private).

### Tiêu chí thành công
1. UI có toggle/nút rõ ràng khi soạn ảnh cho public chat, mặc định TẮT (giữ hành vi nén như hiện tại).
2. Khi bật: hiển thị cảnh báo về thời gian/băng thông trước khi gửi (không cần con số chính xác N giây như private, nhưng phải nêu rõ đây sẽ chậm hơn đáng kể và ảnh hưởng cả mesh, không chỉ người gửi).
3. Bytes gửi đi khớp SHA-256 với ảnh gốc khi bật Original — có test xác nhận.
4. Khi tắt (mặc định): hành vi không đổi so với trước, có test regression.
5. Test hiện có vẫn xanh.

**Dừng lại ở đây, trình bày kết quả Phase B, chờ xác nhận trước khi sang Phase C.**

---

## Phase C — Progress/cancel UI cho transfer

### Bối cảnh
Hiện chỉ có debug log (bytes + SHA-256), không có UI cho người dùng thấy tiến độ hay hủy giữa chừng. Với ảnh private 512 KiB mất 25–45 giây, đây không còn là tính năng phụ.

### Đây là phase cần nhiều quyết định thiết kế nhất — trình bày trước khi code, không tự quyết định thay người dùng
1. `TransferProgressManager` hiện đã track progress cấp ảnh (`totalFragments = chunks.count`, `recordFragmentSent`) cho mục đích nội bộ (phân biệt với progress cấp BLE fragment train, đã tách ở vòng concurrency-fix trước). Điều tra: có sẵn observable/publisher nào UI có thể subscribe trực tiếp không, hay cần thêm plumbing mới?
2. Với **cancel**, cần trả lời rõ trước khi code (đây là quyết định sản phẩm, không phải kỹ thuật thuần túy) — trình bày và đề xuất, không tự chọn:
   - Cancel một transfer đang gửi dở nghĩa là gì cụ thể: dừng gửi chunk còn lại + dọn state cục bộ, hay có cần báo cho peer biết transfer đã bị hủy (để tránh peer chờ mãi/timeout)?
   - Nếu đã gửi được vài chunk trước khi cancel, các chunk đó có nằm trên mesh trôi nổi không (không thể "thu hồi" một khi đã broadcast/gửi), và điều đó có ảnh hưởng gì tới trải nghiệm người nhận không?
3. Sau khi có hướng trả lời cho câu 2 (từ người dùng/bạn xác nhận), mới thiết kế UI cụ thể (progress bar/phần trăm, nút cancel) và code.

### Tiêu chí thành công (áp dụng sau khi hướng ở mục 2 đã được xác nhận)
- Progress hiển thị được cho người dùng trong lúc gửi ảnh private (và public-original nếu Phase B đã xong).
- Cancel hoạt động đúng theo định nghĩa đã thống nhất ở bước 2, có test.
- Test hiện có vẫn xanh.

**Dừng lại ở Phase C sau bước điều tra + trình bày câu hỏi thiết kế mục 2 — chờ xác nhận hướng trước khi code UI thật.**

---

## Ràng buộc chung cho cả 3 phase

- Không đụng logic chunking/Noise/reassembly/concurrency-throttle đã có và đã test khóa từ các vòng trước, trừ khi một phase ở trên yêu cầu.
- `swift test && just build` xanh sau mỗi phase; chạy thêm `xcodebuild ... -sdk iphonesimulator` nếu phase đó ảnh hưởng iOS.
- Không claim đã test hardware thật ở bất kỳ phase nào.
