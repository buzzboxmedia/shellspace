#!/usr/bin/env python3
"""
Google Sheets sync for ClaudeHub tasks.
Appends task log entries to a master spreadsheet.

Usage:
    python3 sheets_sync.py log --project "INFAB" --task "Fix checkout" --status "completed" --notes "Fixed the bug"
    python3 sheets_sync.py init  # Creates the spreadsheet if it doesn't exist
    python3 sheets_sync.py list  # Lists recent tasks
    python3 sheets_sync.py auth  # Run OAuth flow (first-time setup)
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

# Suppress SSL warning
import warnings
warnings.filterwarnings("ignore", message="urllib3 v2 only supports OpenSSL")

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# Configuration
CONFIG_DIR = Path.home() / ".claudehub"
TOKEN_PATH = CONFIG_DIR / "sheets_token.json"
CREDENTIALS_PATH = CONFIG_DIR / "google_credentials.json"
SCOPES = [
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive.file"
]

# Spreadsheet config
SPREADSHEET_NAME = "Buzzbox Task Log"
SHEET_NAME = "Tasks"
SPREADSHEET_ID_FILE = CONFIG_DIR / "task_log_sheet_id.txt"

# Column headers
HEADERS = ["Date", "Time", "Project", "Task", "Status", "Notes"]


def get_credentials():
    """Get valid user credentials, prompting for auth if needed."""
    creds = None
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if TOKEN_PATH.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_PATH), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
            except Exception:
                creds = None

        if not creds:
            # Need to run auth flow
            print(json.dumps({
                "success": False,
                "error": "Not authenticated. Run: python3 sheets_sync.py auth",
                "needs_auth": True
            }))
            sys.exit(1)

        # Save refreshed credentials
        with open(TOKEN_PATH, "w") as f:
            f.write(creds.to_json())

    return creds


def run_auth_flow():
    """Run the OAuth2 authorization flow."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if not CREDENTIALS_PATH.exists():
        setup_instructions = """
To set up Google Sheets integration:

1. Go to https://console.cloud.google.com/apis/credentials
2. Create a project (or select existing)
3. Enable the Google Sheets API and Google Drive API
4. Create OAuth 2.0 credentials (Desktop app)
5. Download the JSON file
6. Save it to: ~/.claudehub/google_credentials.json

Then run this command again.
"""
        print(json.dumps({
            "success": False,
            "error": "Credentials file not found",
            "instructions": setup_instructions.strip(),
            "path": str(CREDENTIALS_PATH)
        }))
        sys.exit(1)

    print("Opening browser for Google authorization...", file=sys.stderr)
    print("Please sign in and authorize access to Google Sheets.", file=sys.stderr)

    flow = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS_PATH), SCOPES)

    try:
        creds = flow.run_local_server(port=8085, open_browser=True)
    except Exception as e:
        # Fallback to console-based flow
        print(f"Browser flow failed: {e}", file=sys.stderr)
        print("Using manual authorization...", file=sys.stderr)
        creds = flow.run_console()

    with open(TOKEN_PATH, "w") as f:
        f.write(creds.to_json())

    print(json.dumps({"success": True, "message": "Authorization successful!"}))
    return creds


def get_sheets_service():
    """Get authenticated Sheets API service."""
    creds = get_credentials()
    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def get_drive_service():
    """Get authenticated Drive API service."""
    creds = get_credentials()
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def get_spreadsheet_id():
    """Get the spreadsheet ID from local cache."""
    if SPREADSHEET_ID_FILE.exists():
        return SPREADSHEET_ID_FILE.read_text().strip()
    return None


def save_spreadsheet_id(spreadsheet_id):
    """Save spreadsheet ID to local cache."""
    SPREADSHEET_ID_FILE.parent.mkdir(parents=True, exist_ok=True)
    SPREADSHEET_ID_FILE.write_text(spreadsheet_id)


def find_existing_spreadsheet():
    """Search for existing Buzzbox Task Log spreadsheet."""
    try:
        drive = get_drive_service()
        results = drive.files().list(
            q=f"name='{SPREADSHEET_NAME}' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
            spaces="drive",
            fields="files(id, name)"
        ).execute()

        files = results.get("files", [])
        if files:
            return files[0]["id"]
    except HttpError:
        pass
    return None


def create_spreadsheet():
    """Create a new spreadsheet with headers."""
    sheets = get_sheets_service()

    spreadsheet = sheets.spreadsheets().create(
        body={
            "properties": {"title": SPREADSHEET_NAME},
            "sheets": [{
                "properties": {
                    "title": SHEET_NAME,
                    "gridProperties": {"frozenRowCount": 1}
                }
            }]
        }
    ).execute()

    spreadsheet_id = spreadsheet["spreadsheetId"]

    # Add headers
    sheets.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A1",
        valueInputOption="RAW",
        body={"values": [HEADERS]}
    ).execute()

    # Format header row (bold, background color)
    sheets.spreadsheets().batchUpdate(
        spreadsheetId=spreadsheet_id,
        body={
            "requests": [
                {
                    "repeatCell": {
                        "range": {
                            "sheetId": 0,
                            "startRowIndex": 0,
                            "endRowIndex": 1
                        },
                        "cell": {
                            "userEnteredFormat": {
                                "backgroundColor": {"red": 0.2, "green": 0.2, "blue": 0.3},
                                "textFormat": {"bold": True, "foregroundColor": {"red": 1, "green": 1, "blue": 1}}
                            }
                        },
                        "fields": "userEnteredFormat(backgroundColor,textFormat)"
                    }
                },
                {
                    "updateSheetProperties": {
                        "properties": {
                            "sheetId": 0,
                            "gridProperties": {"frozenRowCount": 1}
                        },
                        "fields": "gridProperties.frozenRowCount"
                    }
                }
            ]
        }
    ).execute()

    return spreadsheet_id


def ensure_spreadsheet():
    """Ensure spreadsheet exists, create if needed. Returns spreadsheet ID."""
    # Check cache first
    spreadsheet_id = get_spreadsheet_id()
    if spreadsheet_id:
        # Verify it still exists
        try:
            sheets = get_sheets_service()
            sheets.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
            return spreadsheet_id
        except HttpError:
            pass  # Spreadsheet was deleted, recreate

    # Search for existing
    spreadsheet_id = find_existing_spreadsheet()
    if spreadsheet_id:
        save_spreadsheet_id(spreadsheet_id)
        return spreadsheet_id

    # Create new
    spreadsheet_id = create_spreadsheet()
    save_spreadsheet_id(spreadsheet_id)
    print(f"Created new spreadsheet: https://docs.google.com/spreadsheets/d/{spreadsheet_id}", file=sys.stderr)
    return spreadsheet_id


def log_task(project: str, task: str, status: str, notes: str):
    """Append a task log entry to the spreadsheet."""
    spreadsheet_id = ensure_spreadsheet()
    sheets = get_sheets_service()

    now = datetime.now()
    row = [
        now.strftime("%Y-%m-%d"),
        now.strftime("%H:%M"),
        project,
        task,
        status,
        notes
    ]

    sheets.spreadsheets().values().append(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A:F",
        valueInputOption="RAW",
        insertDataOption="INSERT_ROWS",
        body={"values": [row]}
    ).execute()

    result = {
        "success": True,
        "spreadsheet_id": spreadsheet_id,
        "url": f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}",
        "logged": {
            "date": row[0],
            "time": row[1],
            "project": project,
            "task": task,
            "status": status
        }
    }
    print(json.dumps(result))
    return result


def list_tasks(limit: int = 10):
    """List recent tasks from the spreadsheet."""
    spreadsheet_id = get_spreadsheet_id()
    if not spreadsheet_id:
        print(json.dumps({"success": False, "error": "No spreadsheet configured. Run 'init' first."}))
        return

    sheets = get_sheets_service()

    result = sheets.spreadsheets().values().get(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A:F"
    ).execute()

    rows = result.get("values", [])
    if len(rows) <= 1:
        print(json.dumps({"success": True, "tasks": []}))
        return

    # Skip header, get last N rows
    tasks = []
    for row in rows[-limit:]:
        if len(row) >= 5:
            tasks.append({
                "date": row[0] if len(row) > 0 else "",
                "time": row[1] if len(row) > 1 else "",
                "project": row[2] if len(row) > 2 else "",
                "task": row[3] if len(row) > 3 else "",
                "status": row[4] if len(row) > 4 else "",
                "notes": row[5] if len(row) > 5 else ""
            })

    print(json.dumps({"success": True, "tasks": tasks}))


def init_spreadsheet():
    """Initialize/ensure spreadsheet exists."""
    spreadsheet_id = ensure_spreadsheet()
    result = {
        "success": True,
        "spreadsheet_id": spreadsheet_id,
        "url": f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}"
    }
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description="ClaudeHub Google Sheets sync")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Auth command
    subparsers.add_parser("auth", help="Authorize with Google")

    # Log command
    log_parser = subparsers.add_parser("log", help="Log a task")
    log_parser.add_argument("--project", required=True, help="Project name")
    log_parser.add_argument("--task", required=True, help="Task name")
    log_parser.add_argument("--status", default="completed", help="Task status")
    log_parser.add_argument("--notes", default="", help="Task notes/summary")

    # Init command
    subparsers.add_parser("init", help="Initialize spreadsheet")

    # List command
    list_parser = subparsers.add_parser("list", help="List recent tasks")
    list_parser.add_argument("--limit", type=int, default=10, help="Number of tasks to show")

    args = parser.parse_args()

    try:
        if args.command == "auth":
            run_auth_flow()
        elif args.command == "log":
            log_task(args.project, args.task, args.status, args.notes)
        elif args.command == "init":
            init_spreadsheet()
        elif args.command == "list":
            list_tasks(args.limit)
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
