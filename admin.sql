-- Dán TOÀN BỘ file này vào Supabase > SQL Editor rồi bấm Run.
-- Đặt mật khẩu 134234, xác nhận email, cấp quyền admin (không phân biệt chữ hoa/thường của email).
update auth.users
set encrypted_password = extensions.crypt('134234', extensions.gen_salt('bf')),
    email_confirmed_at = coalesce(email_confirmed_at, now()),
    raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || '{"role":"admin"}'::jsonb
where lower(email) = 'mdpmblack2006@gmail.com';

-- BẢNG KẾT QUẢ: phải ra đúng 1 dòng, mật_khau_dung = true, la_admin = admin.
select email,
       (encrypted_password = extensions.crypt('134234', encrypted_password)) as mat_khau_dung,
       raw_app_meta_data ->> 'role' as la_admin,
       email_confirmed_at is not null as da_xac_nhan,
       banned_until
from auth.users
where lower(email) = 'mdpmblack2006@gmail.com';
