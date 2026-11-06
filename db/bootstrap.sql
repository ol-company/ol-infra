-- =============================================================================
-- Khởi tạo role và database cho mọi service (idempotent — chạy lại bao nhiêu lần cũng được).
-- Chạy bằng tài khoản quản trị DB (local: postgres; AWS: master user do RDS quản lý).
-- Mật khẩu truyền qua biến psql (-v), KHÔNG ghi trong file:
--   psql -v keycloak_password=... -v iam_app_password=... -v iam_migrator_password=... \
--        -v warehouse_app_password=... -v warehouse_migrator_password=... \
--        -v bff_app_password=... -v bff_migrator_password=... -f bootstrap.sql
--
-- Mô hình quyền cho mỗi service X:
--   X_migrator : sở hữu database + schema, chạy migration (DDL). Không dùng trong ứng dụng.
--   X_app      : role ứng dụng, chỉ SELECT/INSERT/UPDATE/DELETE. Không phải chủ bảng → bị RLS ràng buộc.
-- Service A không có quyền CONNECT vào database của service B.
-- =============================================================================
\set ON_ERROR_STOP on

-- 1) Tạo role nếu chưa có (\gexec chạy từng câu lệnh mà SELECT sinh ra)
SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY['keycloak','iam_migrator','iam_app','warehouse_migrator','warehouse_app','bff_migrator','bff_app']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

-- 2) Đặt (lại) mật khẩu — cũng là cách xoay vòng mật khẩu khi Secrets Manager đổi giá trị
ALTER ROLE keycloak           PASSWORD :'keycloak_password';
ALTER ROLE iam_migrator       PASSWORD :'iam_migrator_password';
ALTER ROLE iam_app            PASSWORD :'iam_app_password';
ALTER ROLE warehouse_migrator PASSWORD :'warehouse_migrator_password';
ALTER ROLE warehouse_app      PASSWORD :'warehouse_app_password';
ALTER ROLE bff_migrator       PASSWORD :'bff_migrator_password';
ALTER ROLE bff_app            PASSWORD :'bff_app_password';

-- Giới hạn kết nối mỗi role — bảo vệ RDS khỏi một service rò kết nối
ALTER ROLE iam_app CONNECTION LIMIT 60;
ALTER ROLE warehouse_app CONNECTION LIMIT 60;
ALTER ROLE bff_app CONNECTION LIMIT 60;
ALTER ROLE keycloak CONNECTION LIMIT 60;

-- 3) Tài khoản quản trị cần là thành viên các role chủ sở hữu để tạo DB/schema thay mặt chúng
GRANT keycloak, iam_migrator, warehouse_migrator, bff_migrator TO CURRENT_USER;

-- 4) Database, mỗi service một database
SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak') \gexec
SELECT 'CREATE DATABASE iam OWNER iam_migrator' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'iam') \gexec
SELECT 'CREATE DATABASE warehouse OWNER warehouse_migrator' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'warehouse') \gexec
SELECT 'CREATE DATABASE bff OWNER bff_migrator' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bff') \gexec

-- 5) Schema + quyền mặc định trong từng database
\connect iam
CREATE SCHEMA IF NOT EXISTS iam AUTHORIZATION iam_migrator;
GRANT USAGE ON SCHEMA iam TO iam_app;
ALTER DEFAULT PRIVILEGES FOR ROLE iam_migrator IN SCHEMA iam GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO iam_app;
ALTER DEFAULT PRIVILEGES FOR ROLE iam_migrator IN SCHEMA iam GRANT USAGE, SELECT ON SEQUENCES TO iam_app;
ALTER DEFAULT PRIVILEGES FOR ROLE iam_migrator IN SCHEMA iam GRANT EXECUTE ON FUNCTIONS TO iam_app;

\connect warehouse
CREATE SCHEMA IF NOT EXISTS warehouse AUTHORIZATION warehouse_migrator;
GRANT USAGE ON SCHEMA warehouse TO warehouse_app;
ALTER DEFAULT PRIVILEGES FOR ROLE warehouse_migrator IN SCHEMA warehouse GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO warehouse_app;
ALTER DEFAULT PRIVILEGES FOR ROLE warehouse_migrator IN SCHEMA warehouse GRANT USAGE, SELECT ON SEQUENCES TO warehouse_app;

\connect bff
CREATE SCHEMA IF NOT EXISTS bff AUTHORIZATION bff_migrator;
GRANT USAGE ON SCHEMA bff TO bff_app;
ALTER DEFAULT PRIVILEGES FOR ROLE bff_migrator IN SCHEMA bff GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bff_app;

-- 6) Khóa kết nối chéo: chỉ đúng role được CONNECT vào database của mình
\connect postgres
REVOKE CONNECT ON DATABASE iam, warehouse, bff, keycloak FROM PUBLIC;
GRANT CONNECT ON DATABASE iam TO iam_migrator, iam_app, CURRENT_USER;
GRANT CONNECT ON DATABASE warehouse TO warehouse_migrator, warehouse_app, CURRENT_USER;
GRANT CONNECT ON DATABASE bff TO bff_migrator, bff_app, CURRENT_USER;
GRANT CONNECT ON DATABASE keycloak TO keycloak, CURRENT_USER;
