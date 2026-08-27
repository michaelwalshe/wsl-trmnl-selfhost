"""One-off: authorise this server against your Google Calendar.

Run once, interactively, from the app/ directory:

    uv run authorize_google.py

Opens (or prints, if it can't auto-open a browser) a Google consent URL.
After you click Allow, writes secrets/google_token.json holding a refresh
token, which the data service then uses indefinitely without further
prompts. Read-only scope only: this can never modify your calendars.
"""

from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

SECRETS_DIR = Path(__file__).resolve().parent.parent / "secrets"
CLIENT_SECRET_FILE = SECRETS_DIR / "client_secret.json"
TOKEN_FILE = SECRETS_DIR / "google_token.json"
SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]


def main() -> None:
    if TOKEN_FILE.exists():
        print(f"{TOKEN_FILE} already exists. Delete it first if you want to re-authorise.")
        return

    flow = InstalledAppFlow.from_client_secrets_file(str(CLIENT_SECRET_FILE), SCOPES)
    # Runs a tiny local web server to catch Google's redirect after you approve.
    # WSL's localhost is reachable from Windows (mirrored networking), so opening
    # the printed URL in your normal Windows browser works fine.
    credentials = flow.run_local_server(port=8765, open_browser=False)

    TOKEN_FILE.write_text(credentials.to_json(), encoding="utf-8")
    print(f"Saved refresh token to {TOKEN_FILE}")


if __name__ == "__main__":
    main()
