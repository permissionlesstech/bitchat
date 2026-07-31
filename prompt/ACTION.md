# Nhiệm vụ: Private image/file transfer — giữ chất lượng gốc tuyệt đối + E2EE thật qua Noise

## Bối cảnh (đã điều tra sẵn — không cần khảo sát lại từ đầu)

Repo: `/Users/phamtunganh/Documents/bitchat` (checkout local của permissionlesstech/bitchat).

Điều tra trước đó đã xác định:

- `bitchat/Features/media/ImageUtils.swift:15` — resize + JPEG compress (maxDimension 448, quality 0.82, target ~45KB). Đây là nguồn gây mất chất lượng.
- `bitchat/ViewModels/ChatMediaPreparation.swift:36` — gọi `ImageUtils.processImage`, tạo `BitchatFilePacket` MIME `image/jpeg`.
- `localPackages/BitFoundation/Sources/BitFoundation/FileTransferLimits.swift:2` — `maxPayloadBytes = 1 MiB`, `maxImageBytes = 512 KiB`.
- `bitchat/Protocols/BitchatFilePacket.swift:20` — TLV encode/decode, reject nếu vượt `maxPayloadBytes`.
- `bitchat/Services/BLE/BLEService.swift:899` (`sendFileBroadcast`), `:935` (`sendFilePrivate`).
- `bitchat/Services/BLE/BLEOutboundFragmentPlanner.swift:23` — chia packet thành fragment BLE.
- `bitchat/Services/TransportConfig.swift:7` — fragment size 469 byte, concurrent transfer 2.
- **Phát hiện quan trọng nhất**: `sendFilePrivate` hiện dùng `MessageType.fileTransfer` — được ký (signed), fragment, và **broadcast**. Nó **không** đi qua `NoisePayloadType.privateMessage`. Nghĩa là ảnh "private" hiện tại chỉ được xác thực chống giả mạo, KHÔNG được mã hóa nội dung bằng Noise — bất kỳ relay node nào trên đường đi đều đọc được ảnh gốc.
- Đường mã hóa Noise thật nằm ở `bitchat/Services/BLE/BLEService.swift:3401`, factory tại `bitchat/Services/BLE/BLENoisePayloadFactory.swift:3`, giới hạn tại `NoiseSecurityConstants.maxMessageSize = 65535` (`bitchat/Noise/NoiseSecurityConstants.swift:11`).
- Cipher suite Noise trong checkout này: Curve25519 / ChaCha20-Poly1305 / SHA-256 (Noise XX).
- Message type mới có thể thêm tại `bitchat/Protocols/BitchatProtocol.swift:72` (ví dụ `case fileTransfer = 0x09`), handler inbound tại `bitchat/ViewModels/ChatTransportEventCoordinator.swift:337`.

## Phạm vi

Chỉ áp dụng cho **private / direct-peer image send** (1-1, không phải broadcast/public channel). Public/broadcast image path giữ nguyên hành vi hiện tại (vẫn nén như cũ) — nếu bạn thấy có lý do kỹ thuật để mở rộng ra cả broadcast, hãy nêu rõ giả định đó và hỏi trước khi làm, đừng tự ý mở rộng phạm vi.

## Tiêu chí thành công (bắt buộc, verify được — không phải hướng dẫn từng bước)

Nhiệm vụ chỉ được coi là hoàn thành khi **cả 4 điều dưới đây đều được test tự động chứng minh**, không phải khi code "trông có vẻ đúng":

1. **Byte-identical**: gửi một ảnh private từ peer A đến peer B, ảnh nhận được ở B có SHA-256 khớp 100% với ảnh gốc gửi từ A. Không resize, không recompress, không strip metadata âm thầm.
2. **E2EE thật, không phải chỉ ký số**: toàn bộ nội dung ảnh private phải đi qua Noise session đã thiết lập với peer đó trước khi rời thiết bị. Viết một test/kiểm chứng cho thấy nếu quan sát packet trên "wire" (không có Noise session key), không thể khôi phục được bất kỳ byte ảnh plaintext nào. Không được còn đường nào cho private send đi qua `MessageType.fileTransfer` dạng ký-nhưng-không-mã-hóa như hiện tại.
3. **Không phá vỡ hiện trạng**: `just check && just build` pass, toàn bộ test suite hiện có (bao gồm `FragmentationTests`, `ImageUtilsTests`, `ChatMediaPreparationTests`) vẫn pass hoặc được cập nhật có chủ đích (nêu rõ lý do nếu sửa expectation). Public/broadcast image path không bị đổi hành vi.
4. **Test cho edge case**: có test cho ảnh vượt `maxImageBytes`/`maxPayloadBytes` (phải bị reject rõ ràng, không silent fail), và test cho encode/decode round-trip của message type Noise mới.

## Trước khi viết code — bắt buộc trình bày rồi mới code

Đừng code ngay. Trước tiên:

1. Xác nhận lại các file/dòng ở phần "Bối cảnh" còn đúng với trạng thái repo hiện tại (code có thể đã đổi từ lúc điều tra). Nếu khác, nêu rõ khác gì.
2. Có ít nhất 2 cách để đưa ảnh private vào Noise-encrypted channel trong khi vẫn tôn trọng an toàn (chống DoS/memory):
   - **A. Nâng `NoiseSecurityConstants.maxMessageSize`** lên đủ chứa `maxImageBytes` (hoặc `maxPayloadBytes`) trong một Noise message duy nhất.
   - **B. Giữ nguyên `maxMessageSize = 65535`**, chia ảnh thành nhiều Noise message độc lập (mỗi cái ≤ 64 KiB, mỗi cái tự mã hóa/xác thực qua đúng Noise session), kèm metadata sequence/total/SHA-256 tổng ở message đầu để bên nhận reassemble và verify trước khi hiển thị.
   - Trình bày ngắn gọn trade-off thật giữa hai cách (rủi ro buffer lớn/DoS vs. độ phức tạp reassembly ở tầng app), chọn một cách, giải thích tại sao — thiên hướng đề xuất là cách B vì không đụng safety margin đang bảo vệ chống DoS, nhưng nếu bạn thấy A hợp lý hơn với codebase này thì cứ đề xuất và giải thích.
3. Nêu rõ mọi giả định trước khi code (ví dụ: xử lý timeout/reassembly cho transfer lớn hơn, có cần đổi `bleMaxConcurrentTransfers` không, EXIF/GPS có bị giữ nguyên trong ảnh gốc hay không). Nếu có giả định thật sự chặn tiến độ (không thể tự quyết định hợp lý), dừng lại và hỏi thay vì đoán.

## Ràng buộc khi code

- Chỉ sửa đúng những gì cần để đạt 4 tiêu chí thành công ở trên. Không refactor code đang chạy tốt, không đổi tên symbol không cần thiết, không thêm abstraction/dependency mới không phục vụ trực tiếp mục tiêu này.
- Giữ nguyên style code hiện có trong từng file bị sửa.
- Không đụng vào public/broadcast image path, không đụng `TransportConfig` (fragment size, concurrent transfer) trừ khi bạn chứng minh được nó thật sự cần để đạt tiêu chí thành công — nếu vậy, nêu lý do trước khi sửa.
- Không tự ý thêm tính năng ngoài phạm vi (ví dụ: không cần làm UI toggle "Original quality", không cần xử lý voice note, không cần thêm nén lossless PNG/WebP — những cái đó là việc khác, không phải nhiệm vụ này).

## Sau khi code

Chạy `just check && just build` cùng test mới/cũ, lặp lại tới khi cả 4 tiêu chí thành công đều pass. Báo cáo: file nào đã sửa, vì sao, và cách nào (A hay B) đã chọn cho việc đưa ảnh vào Noise channel.
