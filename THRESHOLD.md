# Nhiệm vụ: Làm minh bạch công thức tính threshold N/M trong TESTING_HARDWARE_VERIFICATION.md

## Bối cảnh

Toàn bộ implementation (private image gửi byte gốc qua Noise-encrypted chunk), concurrency fix (fragmentTrainId chia sẻ đúng global pool `bleMaxConcurrentTransfers = 2` giữa public fileTransfer và private noiseEncrypted chunks), instrumentation debug log, và test coverage đã hoàn tất, xanh toàn bộ (1634 tests pass, `just build` thành công). Đây **không phải** task sửa logic transfer/scheduler mới — chỉ còn một câu hỏi cần đóng trước khi bàn giao runbook cho vòng test tay phần cứng.

## Câu hỏi cụ thể cần trả lời bằng công thức, không phải chỉ đưa số

Runbook hiện ghi N (1-hop, ảnh 512 KiB) = 25 giây, dựa trên model "4 wave × 132 fragments + 1 wave × 70 fragments" (mỗi wave gồm 2 chunk chạy song song nhờ `bleMaxConcurrentTransfers = 2`, trừ wave cuối chỉ còn 1 chunk lẻ).

Nếu 2 train trong cùng một wave thực sự chạy song song, thời gian của wave đó phải bằng thời gian của train **dài hơn** trong cặp (max), không phải tổng 2 train cộng lại (sum) — vì 2 train chạy đồng thời, không nối đuôi nhau. Với input hiện tại, mô hình song song thuần cho:

```
(4 × 132 fragments + 1 × 70 fragments) × spacing(25ms) ≈ 15 giây
```

không phải 25 giây như đang ghi. Trả lời rõ: con số 25 giây hiện tại đến từ đâu — hai khả năng:

- **(a)** Là 15 giây lý thuyết + margin an toàn ~10 giây cho overhead thực tế (GATT negotiation, ack, thời gian xử lý mã hóa mỗi chunk, biến động radio BLE thật) — margin có chủ đích.
- **(b)** Công thức tính đang vô tình cộng dồn 2 train trong cùng 1 wave như thể chạy tuần tự (sum thay vì max) — nghĩa là công thức sai.

## Việc cần làm, theo đúng câu trả lời ở trên

**Nếu là (a) — margin có chủ đích:**
Sửa đúng đoạn ghi threshold trong `TESTING_HARDWARE_VERIFICATION.md` để hiện rõ công thức, ví dụ dạng:
`lower-bound lý thuyết (song song, 2-concurrent) = 15s; threshold N = lower-bound + 10s margin (GATT/ack/encryption overhead) = 25s`
Không để threshold hiện ra như một con số trần trụi không giải thích được.

**Nếu là (b) — công thức sai:**
Sửa lại phép tính cho đúng model song song (max, không phải sum), cập nhật N. Áp dụng đúng cách kiểm tra tương tự cho M (ngưỡng ≥2-hop, hiện 45s / 60s timeout) — vì nếu N bị tính sai kiểu cộng dồn, M rất có khả năng dính lỗi tương tự (relay thêm 1 hop cũng là một dạng "chuỗi" thời gian dễ bị cộng nhầm).

**Dù đi theo (a) hay (b)**, kết quả cuối trong runbook phải để lộ công thức ngay tại chỗ ghi số — mỗi threshold (N và M) cần kèm 1-2 dòng: lower-bound tính từ đâu, margin (nếu có) là bao nhiêu và vì sao.

## Ràng buộc

- Không đụng code production (BLEService, scheduler, ImageUtils, v.v.) trừ khi câu trả lời cho thấy đây thực sự là bug trong công thức threshold — và ngay cả vậy, chỉ sửa phần tính/ghi threshold trong runbook, không sửa logic transfer/scheduler đã có test khóa.
- Không mở rộng thêm case mới hay tính năng mới ngoài việc làm rõ 2 threshold này.
- Giữ nguyên toàn bộ test đang pass (1634 tests), không cần chạy lại `swift test`/`just build` nếu không đụng code (chỉ sửa file markdown).

## Sau khi xong

Trình bày: công thức cuối cùng cho cả N và M (kèm số liệu), câu trả lời (a) hay (b), và xác nhận đây là bước cuối cùng trước khi bàn giao `TESTING_HARDWARE_VERIFICATION.md` cho việc test tay 2–3 thiết bị thật.
