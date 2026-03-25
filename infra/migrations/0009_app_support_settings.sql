CREATE TABLE IF NOT EXISTS app_support_settings (
  id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  support_email TEXT,
  support_phone TEXT,
  office_hours TEXT,
  help_text TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL
);

INSERT INTO app_support_settings (
  id,
  support_email,
  support_phone,
  office_hours,
  help_text
)
VALUES (
  1,
  NULL,
  NULL,
  NULL,
  NULL
)
ON CONFLICT (id) DO NOTHING;
