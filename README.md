<h1 align="center">
  <br />
  <img src="https://github.com/D0nKarnag3/azure_devops.nvim/assets/1623724/aadaecce-838c-49e4-b131-30b40e77f44a" alt="Logo" width="280"/>
  <br />
  AzureDevOps.nvim
  <br />
</h1>

A Neovim plugin to interact with Azure DevOps work items directly within your editor.

`azure_devops.nvim` allows you to efficiently view, manage, and update Azure DevOps work items right from Neovim. Whether you're managing bugs, features, or tasks, this plugin integrates seamlessly into your workflow.

## ✨ Features

- View and search work items from Azure DevOps
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
  "d0nkarnge/flux.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("azure_devops").setup({
      personal_access_token = os.getenv("AZURE_PAT"),
      organization = os.getenv("AZURE_ORG"),
      project = os.getenv("AZURE_PROJ"),
      show_work_item_icon = true
    })
  end
}
```

## ⚙️ Configuration
