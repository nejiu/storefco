-- Dán TOÀN BỘ file này vào Supabase > SQL Editor rồi bấm Run.
-- Việc làm: đặt mật khẩu 134234, xác nhận email, cấp quyền admin cho tài khoản quản lý.
-- Điều kiện: user mdpmblack2006@gmail.com đã có trong Authentication > Users (chưa có thì Add user trước).

update auth.users
set encrypted_password = extensions.crypt('134234', extensions.gen_salt('bf')),
    email_confirmed_at = coalesce(email_confirmed_at, now()),
    raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || '{"role":"admin"}'::jsonb
where email = 'mdpmblack2006@gmail.com';

-- Kết quả phải ra 1 dòng, cột raw_app_meta_data có "role": "admin". Không ra dòng nào = chưa có user.
select email, raw_app_meta_data, email_confirmed_at from auth.users where email = 'mdpmblack2006@gmail.com';
