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
DEFAULT_SPREADSHEET_NAME = "Buzzbox Task Log"
SHEET_NAME = "Tasks"

# Workspaces with their own spreadsheets
WORKSPACE_SPREADSHEETS = {
    "Talkspresso": "Talkspresso Task Log",
    "Miller": "Miller Task Log",
}


def get_spreadsheet_id_file(workspace: str = None):
    """Get the spreadsheet ID file path for a workspace."""
    if workspace and workspace in WORKSPACE_SPREADSHEETS:
        return CONFIG_DIR / f"task_log_sheet_id_{workspace.lower()}.txt"
    return CONFIG_DIR / "task_log_sheet_id.txt"


def get_spreadsheet_name(workspace: str = None):
    """Get the spreadsheet name for a workspace."""
    if workspace and workspace in WORKSPACE_SPREADSHEETS:
        return WORKSPACE_SPREADSHEETS[workspace]
    return DEFAULT_SPREADSHEET_NAME

# Column headers
HEADERS = ["Date", "Time", "Workspace", "Project", "Task", "Description", "Est Hrs", "Actual Hrs", "Status", "Notes"]


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


def get_spreadsheet_id(workspace: str = None):
    """Get the spreadsheet ID from local cache."""
    id_file = get_spreadsheet_id_file(workspace)
    if id_file.exists():
        return id_file.read_text().strip()
    return None


def save_spreadsheet_id(spreadsheet_id, workspace: str = None):
    """Save spreadsheet ID to local cache."""
    id_file = get_spreadsheet_id_file(workspace)
    id_file.parent.mkdir(parents=True, exist_ok=True)
    id_file.write_text(spreadsheet_id)


def find_existing_spreadsheet(workspace: str = None):
    """Search for existing spreadsheet by name."""
    spreadsheet_name = get_spreadsheet_name(workspace)
    try:
        drive = get_drive_service()
        results = drive.files().list(
            q=f"name='{spreadsheet_name}' and mimeType='application/vnd.google-apps.spreadsheet' and trashed=false",
            spaces="drive",
            fields="files(id, name)"
        ).execute()

        files = results.get("files", [])
        if files:
            return files[0]["id"]
    except HttpError as e:
        print(f"Drive search error: {e}", file=sys.stderr)
    return None


def create_spreadsheet(workspace: str = None):
    """Create a new spreadsheet with headers and nice styling."""
    sheets = get_sheets_service()
    spreadsheet_name = get_spreadsheet_name(workspace)

    spreadsheet = sheets.spreadsheets().create(
        body={
            "properties": {"title": spreadsheet_name},
            "sheets": [{
                "properties": {
                    "title": SHEET_NAME,
                    "gridProperties": {"frozenRowCount": 1}
                }
            }]
        }
    ).execute()

    spreadsheet_id = spreadsheet["spreadsheetId"]
    sheet_id = spreadsheet["sheets"][0]["properties"]["sheetId"]

    # Add headers
    sheets.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A1",
        valueInputOption="RAW",
        body={"values": [HEADERS]}
    ).execute()

    # Style the spreadsheet
    sheets.spreadsheets().batchUpdate(
        spreadsheetId=spreadsheet_id,
        body={
            "requests": [
                # Header row: dark purple background, white bold text
                {
                    "repeatCell": {
                        "range": {"sheetId": sheet_id, "startRowIndex": 0, "endRowIndex": 1},
                        "cell": {
                            "userEnteredFormat": {
                                "backgroundColor": {"red": 0.4, "green": 0.2, "blue": 0.6},
                                "textFormat": {
                                    "bold": True,
                                    "fontSize": 11,
                                    "foregroundColor": {"red": 1, "green": 1, "blue": 1}
                                },
                                "horizontalAlignment": "CENTER",
                                "verticalAlignment": "MIDDLE"
                            }
                        },
                        "fields": "userEnteredFormat(backgroundColor,textFormat,horizontalAlignment,verticalAlignment)"
                    }
                },
                # Freeze header row
                {
                    "updateSheetProperties": {
                        "properties": {
                            "sheetId": sheet_id,
                            "gridProperties": {"frozenRowCount": 1}
                        },
                        "fields": "gridProperties.frozenRowCount"
                    }
                },
                # Set column widths
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 0, "endIndex": 1},
                    "properties": {"pixelSize": 100}, "fields": "pixelSize"  # Date
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 1, "endIndex": 2},
                    "properties": {"pixelSize": 70}, "fields": "pixelSize"  # Time
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 2, "endIndex": 3},
                    "properties": {"pixelSize": 120}, "fields": "pixelSize"  # Workspace
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 3, "endIndex": 4},
                    "properties": {"pixelSize": 140}, "fields": "pixelSize"  # Project
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 4, "endIndex": 5},
                    "properties": {"pixelSize": 200}, "fields": "pixelSize"  # Task
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 5, "endIndex": 6},
                    "properties": {"pixelSize": 250}, "fields": "pixelSize"  # Description
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 6, "endIndex": 7},
                    "properties": {"pixelSize": 80}, "fields": "pixelSize"  # Est Hrs
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 7, "endIndex": 8},
                    "properties": {"pixelSize": 90}, "fields": "pixelSize"  # Actual Hrs
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 8, "endIndex": 9},
                    "properties": {"pixelSize": 100}, "fields": "pixelSize"  # Status
                }},
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "COLUMNS", "startIndex": 9, "endIndex": 10},
                    "properties": {"pixelSize": 300}, "fields": "pixelSize"  # Notes
                }},
                # Set header row height
                {"updateDimensionProperties": {
                    "range": {"sheetId": sheet_id, "dimension": "ROWS", "startIndex": 0, "endIndex": 1},
                    "properties": {"pixelSize": 36}, "fields": "pixelSize"
                }},
                # Add filter to header
                {"setBasicFilter": {
                    "filter": {
                        "range": {"sheetId": sheet_id, "startRowIndex": 0, "startColumnIndex": 0, "endColumnIndex": 10}
                    }
                }},
            ]
        }
    ).execute()

    return spreadsheet_id


def ensure_spreadsheet(workspace: str = None):
    """Ensure spreadsheet exists, create if needed. Returns spreadsheet ID."""
    # Check cache first
    spreadsheet_id = get_spreadsheet_id(workspace)
    if spreadsheet_id:
        # Verify it still exists
        try:
            sheets = get_sheets_service()
            sheets.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
            return spreadsheet_id
        except HttpError:
            pass  # Spreadsheet was deleted, recreate

    # Search for existing
    spreadsheet_id = find_existing_spreadsheet(workspace)
    if spreadsheet_id:
        save_spreadsheet_id(spreadsheet_id, workspace)
        return spreadsheet_id

    # Create new
    spreadsheet_id = create_spreadsheet(workspace)
    save_spreadsheet_id(spreadsheet_id, workspace)
    spreadsheet_name = get_spreadsheet_name(workspace)
    print(f"Created new spreadsheet '{spreadsheet_name}': https://docs.google.com/spreadsheets/d/{spreadsheet_id}", file=sys.stderr)
    return spreadsheet_id


def log_task(workspace: str, project: str, task: str, description: str,
              est_hours: float, actual_hours: float, status: str, notes: str):
    """Append a task log entry to the spreadsheet."""
    spreadsheet_id = ensure_spreadsheet(workspace)
    sheets = get_sheets_service()

    now = datetime.now()
    row = [
        now.strftime("%Y-%m-%d"),
        now.strftime("%H:%M"),
        workspace,
        project or "—",  # Use dash for quick tasks without a project
        task,
        description,
        est_hours,
        actual_hours,
        status,
        notes
    ]

    sheets.spreadsheets().values().append(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A:J",
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
            "workspace": workspace,
            "project": project,
            "task": task,
            "description": description,
            "est_hours": est_hours,
            "actual_hours": actual_hours,
            "status": status
        }
    }
    print(json.dumps(result))
    return result


def create_project(workspace: str, project: str):
    """Add a project header row to the spreadsheet."""
    spreadsheet_id = ensure_spreadsheet(workspace)
    sheets = get_sheets_service()

    now = datetime.now()
    row = [
        now.strftime("%Y-%m-%d"),
        now.strftime("%H:%M"),
        workspace,
        project,
        f"📁 {project}",  # Task column shows it's a project
        "Project created",
        "",  # No hours for project header
        "",
        "project",  # Status = project
        ""
    ]

    sheets.spreadsheets().values().append(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A:J",
        valueInputOption="RAW",
        insertDataOption="INSERT_ROWS",
        body={"values": [row]}
    ).execute()

    result = {
        "success": True,
        "spreadsheet_id": spreadsheet_id,
        "url": f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}",
        "created": {
            "type": "project",
            "workspace": workspace,
            "project": project
        }
    }
    print(json.dumps(result))
    return result


def create_task(workspace: str, project: str, task: str):
    """Add a new task row to the spreadsheet."""
    spreadsheet_id = ensure_spreadsheet(workspace)
    sheets = get_sheets_service()

    now = datetime.now()
    row = [
        now.strftime("%Y-%m-%d"),
        now.strftime("%H:%M"),
        workspace,
        project or "—",
        task,
        "",  # No description yet
        "",  # No hours yet
        "",
        "created",  # Status = created (not started)
        ""
    ]

    sheets.spreadsheets().values().append(
        spreadsheetId=spreadsheet_id,
        range=f"{SHEET_NAME}!A:J",
        valueInputOption="RAW",
        insertDataOption="INSERT_ROWS",
        body={"values": [row]}
    ).execute()

    result = {
        "success": True,
        "spreadsheet_id": spreadsheet_id,
        "url": f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}",
        "created": {
            "type": "task",
            "workspace": workspace,
            "project": project,
            "task": task
        }
    }
    print(json.dumps(result))
    return result


def list_tasks(limit: int = 10, workspace: str = None):
    """List recent tasks from the spreadsheet."""
    spreadsheet_id = get_spreadsheet_id(workspace)
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
    log_parser.add_argument("--workspace", required=True, help="Workspace name (client or main project)")
    log_parser.add_argument("--project", default="", help="Project name (optional)")
    log_parser.add_argument("--task", required=True, help="Task name")
    log_parser.add_argument("--description", required=True, help="Billable description")
    log_parser.add_argument("--est-hours", type=float, required=True, help="Estimated hours")
    log_parser.add_argument("--actual-hours", type=float, required=True, help="Actual hours")
    log_parser.add_argument("--status", default="completed", help="Task status")
    log_parser.add_argument("--notes", default="", help="Additional notes")

    # Init command
    subparsers.add_parser("init", help="Initialize spreadsheet")

    # List command
    list_parser = subparsers.add_parser("list", help="List recent tasks")
    list_parser.add_argument("--limit", type=int, default=10, help="Number of tasks to show")

    # Create project command
    create_project_parser = subparsers.add_parser("create-project", help="Create a project in the sheet")
    create_project_parser.add_argument("--workspace", required=True, help="Workspace name")
    create_project_parser.add_argument("--project", required=True, help="Project name")

    # Create task command
    create_task_parser = subparsers.add_parser("create-task", help="Create a task in the sheet")
    create_task_parser.add_argument("--workspace", required=True, help="Workspace name")
    create_task_parser.add_argument("--project", default="", help="Project name (optional)")
    create_task_parser.add_argument("--task", required=True, help="Task name")

    args = parser.parse_args()

    try:
        if args.command == "log":
            log_task(
                workspace=args.workspace,
                project=args.project,
                task=args.task,
                description=args.description,
                est_hours=args.est_hours,
                actual_hours=args.actual_hours,
                status=args.status,
                notes=args.notes
            )
        elif args.command == "init":
            init_spreadsheet()
        elif args.command == "list":
            list_tasks(args.limit)
        elif args.command == "create-project":
            create_project(workspace=args.workspace, project=args.project)
        elif args.command == "create-task":
            create_task(workspace=args.workspace, project=args.project, task=args.task)
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
