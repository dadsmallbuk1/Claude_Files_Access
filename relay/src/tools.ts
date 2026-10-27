// MCP tool definitions. The relay advertises these to Claude and forwards each
// call to the iOS app, which implements them in FilesCore/ToolRouter.swift.
// Keep the two in sync when adding or changing a tool.

export interface ToolDefinition {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations?: {
    readOnlyHint?: boolean;
    destructiveHint?: boolean;
    idempotentHint?: boolean;
    openWorldHint?: boolean;
  };
}

const pathProp = (description: string) => ({ type: "string", description });

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
const MUTATING = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

export const TOOLS: ToolDefinition[] = [
  {
    name: "device_status",
    title: "Device status",
    description:
      "Check whether the iOS app is connected, which shared folders (roots) are available, and whether changes are allowed. Call this first.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: READ_ONLY,
  },
  {
    name: "list_directory",
    title: "List directory",
    description:
      "List files and folders. Paths look like '<Root>/sub/folder' where <Root> is a shared folder name from device_status. An empty path lists the roots. Use depth > 1 to see a tree.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("Folder to list, e.g. 'Madeira/prefix/drive_c'. Empty string lists the roots."),
        depth: { type: "integer", minimum: 1, maximum: 8, default: 1, description: "How many levels deep to list." },
        include_hidden: { type: "boolean", default: false, description: "Include dot-files." },
        max_entries: { type: "integer", minimum: 1, maximum: 5000, default: 500 },
      },
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "file_info",
    title: "File info",
    description:
      "Size, dates and type of a file or folder. For .exe/.dll files also reports the PE architecture (x86 vs x64), which is useful for 32/64-bit mismatches. Optionally computes SHA-256.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("File or folder path."),
        sha256: { type: "boolean", default: false, description: "Compute the SHA-256 hash (files only)." },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "read_file",
    title: "Read file",
    description:
      "Read a file. Text is decoded automatically (UTF-8, UTF-16 with BOM, Latin-1 fallback). Images (png/jpg/gif/webp) are returned as images. Other binaries need encoding='base64'. Use offset/length to page through large files; for logs prefer tail_file.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("File path."),
        offset: { type: "integer", minimum: 0, default: 0, description: "Byte offset to start reading at." },
        length: {
          type: "integer",
          minimum: 1,
          maximum: 262144,
          default: 65536,
          description: "Maximum number of bytes to read.",
        },
        encoding: {
          type: "string",
          enum: ["auto", "text", "base64"],
          default: "auto",
          description: "auto = text or image when possible; text = force text decoding; base64 = raw bytes.",
        },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "tail_file",
    title: "Tail file",
    description: "Return the last N lines of a text file (ideal for log files).",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("File path."),
        lines: { type: "integer", minimum: 1, maximum: 5000, default: 200 },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "search",
    title: "Search files",
    description:
      "Search a folder recursively by file name (glob such as '*.log' or 'd3d*.dll') and/or by text content. Content matches return line numbers and the matching lines.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("Folder to search in."),
        name_pattern: { type: "string", description: "Case-insensitive glob matched against file names, e.g. '*.log'." },
        content_pattern: { type: "string", description: "Text to look for inside files (files up to 20 MB)." },
        regex: { type: "boolean", default: false, description: "Treat content_pattern as a regular expression." },
        case_sensitive: { type: "boolean", default: false },
        max_results: { type: "integer", minimum: 1, maximum: 1000, default: 100 },
        include_hidden: { type: "boolean", default: false },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "recent_files",
    title: "Recently modified files",
    description:
      "List the most recently modified files under a folder, newest first. Great for finding which logs or configs changed after the game was last run.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("Folder to scan."),
        within_minutes: { type: "integer", minimum: 1, description: "Only files modified within this many minutes." },
        limit: { type: "integer", minimum: 1, maximum: 500, default: 50 },
        include_hidden: { type: "boolean", default: false },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "write_file",
    title: "Write file",
    description:
      "Create, overwrite or append to a file. Existing files are backed up first and can be restored with undo_change. Use encoding='base64' for binary content. Parent folders are created as needed.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("File path to write."),
        content: { type: "string", description: "File content (text, or base64 when encoding='base64')." },
        encoding: { type: "string", enum: ["text", "base64"], default: "text" },
        mode: {
          type: "string",
          enum: ["overwrite", "append", "create"],
          default: "overwrite",
          description: "create fails if the file already exists.",
        },
      },
      required: ["path", "content"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
  {
    name: "edit_file",
    title: "Edit text file",
    description:
      "Replace exact text in a text file (configs, .ini, .reg, .cfg). The file's original encoding and BOM are preserved. Fails if old_text is not found, or is found more than once without replace_all. Backed up first.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("Text file to edit."),
        old_text: { type: "string", description: "Exact text to find." },
        new_text: { type: "string", description: "Replacement text." },
        replace_all: { type: "boolean", default: false },
      },
      required: ["path", "old_text", "new_text"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
  {
    name: "make_directory",
    title: "Make directory",
    description: "Create a folder (and any missing parent folders).",
    inputSchema: {
      type: "object",
      properties: { path: pathProp("Folder path to create.") },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: { ...MUTATING, idempotentHint: true },
  },
  {
    name: "copy",
    title: "Copy",
    description:
      "Copy a file or folder. Can copy between roots (e.g. from a staging folder into the Wine prefix). If the destination is an existing folder, the item is copied into it. Overwritten items are backed up.",
    inputSchema: {
      type: "object",
      properties: {
        source: pathProp("Item to copy."),
        destination: pathProp("Target path, or an existing folder to copy into."),
        overwrite: { type: "boolean", default: false },
      },
      required: ["source", "destination"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
  {
    name: "move",
    title: "Move / rename",
    description:
      "Move or rename a file or folder. If the destination is an existing folder, the item is moved into it. Overwritten items are backed up.",
    inputSchema: {
      type: "object",
      properties: {
        source: pathProp("Item to move."),
        destination: pathProp("New path, or an existing folder to move into."),
        overwrite: { type: "boolean", default: false },
      },
      required: ["source", "destination"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
  {
    name: "delete",
    title: "Delete",
    description: "Delete a file or folder. The item is moved into the app's backups, so it can be restored with undo_change.",
    inputSchema: {
      type: "object",
      properties: { path: pathProp("Item to delete.") },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: { ...MUTATING, destructiveHint: true },
  },
  {
    name: "download_url",
    title: "Download from URL",
    description:
      "Download a file from an http(s) URL directly onto the device. If destination is an existing folder (or ends with '/'), the file name comes from the URL. Long downloads return a job_id; poll with job_status.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "http or https URL." },
        destination: pathProp("Target file path or folder."),
        overwrite: { type: "boolean", default: false },
      },
      required: ["url", "destination"],
      additionalProperties: false,
    },
    annotations: { ...MUTATING, openWorldHint: true },
  },
  {
    name: "extract_archive",
    title: "Extract archive",
    description:
      "Extract a .zip, .tar, .tar.gz/.tgz or .tar.xz/.txz archive into a folder (e.g. DXVK or VKD3D releases). Use list_only to preview contents. Overwritten files are backed up. Long extractions return a job_id; poll with job_status.",
    inputSchema: {
      type: "object",
      properties: {
        path: pathProp("Archive file."),
        destination: pathProp("Folder to extract into (created if missing). Required unless list_only."),
        overwrite: { type: "boolean", default: false, description: "Overwrite existing files (backed up first)." },
        strip_components: {
          type: "integer",
          minimum: 0,
          default: 0,
          description: "Drop this many leading folders from each entry path, like tar --strip-components.",
        },
        list_only: { type: "boolean", default: false, description: "Only list the archive's entries." },
      },
      required: ["path"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
  {
    name: "job_status",
    title: "Job status",
    description: "Check a long-running download or extraction started by download_url or extract_archive.",
    inputSchema: {
      type: "object",
      properties: { job_id: { type: "string" } },
      required: ["job_id"],
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "list_changes",
    title: "List changes",
    description: "List recent changes made through this connector, newest first, with their change_id for undo_change.",
    inputSchema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 200, default: 20 } },
      additionalProperties: false,
    },
    annotations: READ_ONLY,
  },
  {
    name: "undo_change",
    title: "Undo change",
    description:
      "Revert a change by change_id: restores backed-up files and removes files the change created (those are kept in backups too). Undo newer changes to the same files first.",
    inputSchema: {
      type: "object",
      properties: { change_id: { type: "string" } },
      required: ["change_id"],
      additionalProperties: false,
    },
    annotations: MUTATING,
  },
];

export const TOOL_NAMES = new Set(TOOLS.map((t) => t.name));

/** Tools that may legitimately run for a while on the device. */
export function toolTimeoutMs(name: string): number {
  switch (name) {
    case "search":
    case "recent_files":
    case "download_url":
    case "extract_archive":
    case "copy":
    case "move":
    case "delete":
    case "undo_change":
      return 55_000;
    default:
      return 30_000;
  }
}

export const SERVER_INSTRUCTIONS = `This server gives you access to folders in the iOS Files app on the user's iPhone/iPad through the "Claude Files Access" app. It is mainly used to troubleshoot Windows games running under Wine in the Madeira app.

How paths work:
- Every path starts with a root name (a folder the user shared in the app), e.g. "Madeira/..." or "Downloads/...". Call device_status (or list_directory with an empty path) to see the roots.
- The "AppData" root is the app's own folder: AppData/Logs/app.log is the app's log (useful if the app itself misbehaves) and AppData/Backups holds change backups.
- The app must be open on the device. If a tool says the device is not connected, ask the user to open the Claude Files Access app and keep it open (on iPad it can sit in Split View next to Madeira).

Troubleshooting tips:
- Start by exploring: list_directory with depth 2-3 on the Madeira root, then recent_files to see what changed after the last launch, then tail_file on logs.
- A Wine prefix contains drive_c/, system.reg, user.reg, userdef.reg and dosdevices/. 64-bit DLLs live in drive_c/windows/system32, 32-bit DLLs in drive_c/windows/syswow64. Use file_info to check a DLL's architecture.
- DXVK/VKD3D swaps: download_url the release archive, extract_archive it (list_only first), then copy the x64 DLLs into system32 and the x32 DLLs into syswow64. DLL overrides may also be needed in user.reg ([Software\\\\Wine\\\\DllOverrides]).
- Game-specific logs and configs often live next to the game's .exe or under drive_c/users/<name>/AppData or Documents.

Safety:
- Every overwrite, delete, move, extraction and edit is backed up automatically. Tell the user what you changed and mention that list_changes and undo_change can revert it.
- Explain the change and ask the user before doing anything large or risky (deleting folders, replacing many system DLLs). Prefer edit_file for small config changes.`;
