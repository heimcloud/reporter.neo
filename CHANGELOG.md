# Changelog

## v0.1.5

- Supervision preload no longer sets any environment on Neo's
  `neo-hermes-supervise-{system,docker}-update` units. HOME, HERMES_HOME,
  TELEGRAM_ALLOWED_USERS and TELEGRAM_HOME_CHANNEL are dropped; Neo sets them
  (and, on Neo dev since the group split, TELEGRAM_GROUP_ALLOWED_CHATS). This
  fixes the conflicting definition of TELEGRAM_ALLOWED_USERS against Neo dev,
  where the reporter still joined user and group IDs into one list.
- `nix flake check`: fails if the reporter defines an env key that Neo also
  defines on the same unit (computed from the module system's definitions, no
  hardcoded key list); the placeholder-secrets host now has a user and a
  synthetic group chat and checks that the supervise units carry Neo's own
  Telegram values.

## v0.1.4

- No secrets in the supervise unit environment; token staging limits.
