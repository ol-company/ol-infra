// =============================================================================
// Load test k6 cho luồng nghiệp vụ chính qua BFF (giống người dùng thật): đọc danh sách hàng + nhập/xuất kho.
// Mục tiêu (NFR Bước 0): 50 req/s ổn định 10 phút, đột biến 200 req/s; lỗi < 1%;
//   p95 đọc < 300 ms, p95 ghi < 800 ms.
// Chạy (từ thư mục ol-infra):
//   docker run --rm -i -e BASE_URL -e SESSIONS -e TENANT_ID -e WAREHOUSE_ID -e ITEM_ID grafana/k6 run - < loadtest/warehouse.js
// SESSIONS: danh sách giá trị cookie __Host-ol_session (phân tách bằng dấu phẩy) của các tài khoản kiểm thử,
//           lấy trong DevTools → Application → Cookies sau khi đăng nhập. Không commit giá trị này.
// =============================================================================
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL;
const sessions = (__ENV.SESSIONS || '').split(',').filter(Boolean);
const T = __ENV.TENANT_ID;
const W = __ENV.WAREHOUSE_ID;
const I = __ENV.ITEM_ID;

export const options = {
  scenarios: {
    steady: { executor: 'constant-arrival-rate', rate: 50, timeUnit: '1s', duration: '10m', preAllocatedVUs: 60, maxVUs: 200 },
    spike: {
      executor: 'ramping-arrival-rate',
      startTime: '10m',
      startRate: 50,
      timeUnit: '1s',
      stages: [
        { target: 200, duration: '1m' },
        { target: 200, duration: '2m' },
        { target: 50, duration: '1m' },
      ],
      preAllocatedVUs: 150,
      maxVUs: 400,
    },
  },
  // Không đạt ngưỡng → k6 thoát mã khác 0 → coi như không đạt nghiệm thu hiệu năng
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{type:read}': ['p(95)<300'],
    'http_req_duration{type:write}': ['p(95)<800'],
  },
};

export function setup() {
  if (!BASE || sessions.length === 0 || !T || !W || !I) throw new Error('Thiếu BASE_URL, SESSIONS, TENANT_ID, WAREHOUSE_ID hoặc ITEM_ID');
}

function uuid() {
  // Đủ ngẫu nhiên cho Idempotency-Key trong kiểm thử tải
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export default function () {
  const cookie = `__Host-ol_session=${sessions[__VU % sessions.length]}`;
  const base = `${BASE}/api/warehouse/v1/tenants/${T}/warehouses/${W}`;
  if (Math.random() < 0.8) {
    // 80% đọc
    const res = http.get(`${base}/items`, { headers: { cookie }, tags: { type: 'read' } });
    check(res, { 'đọc 200': (r) => r.status === 200 });
  } else {
    // 20% ghi: +1 rồi lần sau -1 ngẫu nhiên, giữ tồn kho dao động quanh mức ban đầu
    const delta = Math.random() < 0.5 ? '1' : '-1';
    const res = http.post(`${base}/items/${I}/adjustments`, JSON.stringify({ delta, reason: 'load-test' }), {
      headers: { cookie, 'content-type': 'application/json', 'x-ol-csrf': '1', 'idempotency-key': uuid(), origin: BASE },
      tags: { type: 'write' },
      responseCallback: http.expectedStatuses(201, 409), // 409 không tính vào http_req_failed
    });
    // 409 = tồn kho không đủ khi trừ: là hành vi nghiệp vụ đúng, không tính là lỗi hệ thống
    check(res, { 'ghi 201/409': (r) => r.status === 201 || r.status === 409 });
  }
}
