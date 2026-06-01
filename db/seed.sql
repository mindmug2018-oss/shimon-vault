-- ─────────────────────────────────────────────────────────────
-- ShimonVault — Seed Data
-- Demo users for presentation. Passwords are bcrypt hashes.
-- Plain passwords: admin=Admin1234!, editor=Edit5678!, viewer=View9012!
-- ─────────────────────────────────────────────────────────────

INSERT INTO users (id, email, username, password_hash, role) VALUES
  ('00000000-0000-0000-0000-000000000001',
   'admin@shimonvault.local',
   'admin',
   '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewwVQQi.dILFuPqK',  -- Admin1234!
   'admin'),
  ('00000000-0000-0000-0000-000000000002',
   'editor@shimonvault.local',
   'editor',
   '$2b$12$xN5k1QeENR.mY1CZ9BqkHe9E3H0Jfq4kFY5m8dEqk9VdxdBbRzIfy',  -- Edit5678!
   'editor'),
  ('00000000-0000-0000-0000-000000000003',
   'viewer@shimonvault.local',
   'viewer',
   '$2b$12$8Ow3s5z2K9PnmQ1XLJFiOuFxPxhKEKZvnHuFLJJkOH8zIkfbhXFCa',  -- View9012!
   'viewer')
ON CONFLICT DO NOTHING;
