<h1 align="center">
  <br />
  <img src="https://github.com/D0nKarnag3/azure_devops.nvim/assets/1623724/aadaecce-838c-49e4-b131-30b40e77f44a" alt="Logo" width="280"/>
  <br />
  taskmeister.nvim
  <br />
</h1>

A Neovim plugin to interact with Azure DevOps work items directly within your editor.

`taskmeister.nvim` allows you to efficiently view, manage, and update Azure DevOps work items right from Neovim. Whether you're managing bugs, features, or tasks, this plugin integrates seamlessly into your workflow.

## ✨ Features

- View and search work items from Azure DevOps
- Open a personal work dashboard for assigned Azure DevOps items
- Create new work items (e.g., tasks, bugs, features)
- Update work item statuses and assign work
- Seamlessly browse and filter work items by ID, title, or type
- Quick access to work item details and history

## ⚡️ Requirements

- [Neovim](https://neovim.io/) (version 0.5.0 or higher)
- An active Azure DevOps account
- [Azure DevOps Personal Access Token (PAT)](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate)
- `curl` or `http` command-line tool (for API requests)
- a Nerd font for proper icons support

## 📦 Installation

Install the plugin with you package manager

```lua
{
  "d0nkarnge/taskmeister.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("taskmeister").setup({
      personal_access_token = os.getenv("AZURE_PAT"),
      organization = os.getenv("AZURE_ORG"),
      project = os.getenv("AZURE_PROJ"),
      show_work_item_icon = true
    })
  end
}
```

## ⚙️ Configuration

## 🤖 Commands

All commands are routed through a single entrypoint:

```vim
:Taskmeister <subcommand> [args...]
```

| Subcommand | Arguments | Description |
| ---------- | --------- | ----------- |
| `open` | `[id]` | Open a work item buffer |
| `edit` | `[id]` | Open the interactive edit dialog |
| `create` | `<type>` | Create a new work item (`Task`, `Bug`, `Feature`, `User Story`) |
| `dashboard` | none | Open a Telescope dashboard for work assigned to you |
| `list` | `[search terms...]` | Open Telescope list, optionally filtered by title text |
| `comment` | `[id]` | Add a comment to a work item |
| `browser` | `[id]` | Open a work item in your browser |
| `details` | `[id]` | Show details in a floating window |
| `vt-show` | none | Show virtual text annotations in current buffer |
| `vt-clear` | none | Clear virtual text annotations in current buffer |

For ID-based commands (`open`, `edit`, `comment`, `browser`, `details`), if no ID is passed the plugin:
1. Tries `WI123` under cursor
2. Prompts for an ID
