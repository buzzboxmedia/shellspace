#!/usr/bin/env python3
"""
Google Sheets sync for ClaudeHub tasks.
Appends task log entries to a master spreadsheet.

Usage:
    python3 sheets_sync.py log --project "INFAB" --task "Fix checkout" --status "completed" --notes "Fixed the bug"
    python3 sheets_sync.py init  # Creates the spreadsheet if it doesn't exist
    python3 sheets_sync.py list  # Lists recent tasks
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

# Suppress SSL warning
import warnings
warnings.filterwarnings("ignore", message="urllib3 v2 only supports OpenSSL")

from google.oauth2.service_account import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# Configuration
CONFIG_DIR = Path.home() / ".claudehub"
CREDENTIALS_PATH = Path.home() / "Dropbox/Buzzbox/credentials/buzzbox-agency-e2cca1e9d52a.json"
DELEGATED_USER = "baron@buzzboxmedia.com"

SCOPES = [
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/drive"
]

# Spreadsheet config
SPREADSHEET_NAME = "Buzzbox Task Log"
SHEET_NAME = "Tasks"
SPREADSHEET_ID_FILE = CONFIG_DIR / "task_log_sheet_id.txt"

# Column headers
HEADERS = ["Date", "Time", "Project", "Task", "Status", "Notes"]


def get_credentials():
    """Load service account credentials with domain-wide delegation."""
    if not CREDENTIALS_PATH.exists():
        print(json.dumps({
            "success": False,
            "error": f"Credentials not found at {CREDENTIALS_PATH}"
        }))
        sys.exit(1)

    creds = Credentials.from_service_account_file(
        str(CREDENTIALS_PATH),
        scopes=SCOPES,
        subject=DELEGATED_USER
    )
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
    except HttpError as e:
        print(f"Drive search error: {e}", file=sys.stderr)
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
    # Get actual sheet ID from response
    sheet_id = spreadsheet["sheets"][0]["properties"]["sheetId"]

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
                            "sheetId": sheet_id,
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
                            "sheetId": sheet_id,
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
        if args.command == "log":
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
