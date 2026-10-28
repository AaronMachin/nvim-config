return {
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    opts = require "configs.conform",
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      require "configs.lspconfig"
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = {
        "vim",
        "lua",
        "vimdoc",
        "html",
        "css",
        "php",
        "phpdoc",
        "vue",
        "typescript",
        "javascript",
        "tsx",
        "json",
        "yaml",
        "bash",
        "markdown",
        "markdown_inline",
        "dockerfile",
        "sql",
        "regex",
      },
    },
  },

  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  },

  -- s + two letters jumps to any visible word
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = { modes = { search = { enabled = false }, char = { enabled = false } } },
    keys = {
      {
        "s",
        mode = { "n", "x", "o" },
        function()
          require("flash").jump()
        end,
        desc = "flash jump",
      },
    },
  },

  -- Pinned files, kept per branch (see lua/pins)
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
  },

  -- SQL in a buffer against the project's database (see lua/dbkeys)
  {
    "kristijanhusak/vim-dadbod-ui",
    dependencies = { "tpope/vim-dadbod", "kristijanhusak/vim-dadbod-completion" },
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection" },
    init = function()
      vim.g.db_ui_use_nerd_fonts = 1
      vim.g.db_ui_save_location = vim.fn.stdpath "data" .. "/dadbod"
    end,
  },

  -- Claude Code's IDE connection: it sees the file and selection, and its edits open
  -- as diffs here (see lua/agent)
  {
    "coder/claudecode.nvim",
    event = "VeryLazy",
    opts = function()
      return { terminal = { provider = require("agent").provider } }
    end,
    config = function(_, opts)
      require("claudecode").setup(opts)
      -- It only skips its own terminal when telling Claude which file you're in, so any
      -- other terminal tab (the shell a claude was typed in, say) showed up in Claude
      -- as "In zsh". Skip every terminal; files are still reported as before.
      local selection = require "claudecode.selection"
      local update = selection.update_selection
      selection.update_selection = function(...)
        if vim.bo.buftype == "terminal" then
          selection._cancel_demotion_timer()
          return
        end
        return update(...)
      end
    end,
  },

  -- Xdebug through Sail (see lua/debugger)
  {
    "mfussenegger/nvim-dap",
    dependencies = { "rcarriga/nvim-dap-ui", "nvim-neotest/nvim-nio" },
    config = function()
      require "debugger"
    end,
    cmd = { "DapContinue", "DapToggleBreakpoint" },
    keys = {
      {
        "<F5>",
        function()
          require("debugger").continue()
        end,
        desc = "debug start or continue",
      },
      {
        "<F9>",
        function()
          require("debugger").toggle_breakpoint()
        end,
        desc = "debug toggle breakpoint",
      },
      {
        "<F10>",
        function()
          require("debugger").step_over()
        end,
        desc = "debug step over",
      },
      {
        "<F11>",
        function()
          require("debugger").step_into()
        end,
        desc = "debug step into",
      },
      {
        "<F12>",
        function()
          require("debugger").step_out()
        end,
        desc = "debug step out",
      },
      {
        "<leader>db",
        function()
          require("debugger").toggle_breakpoint()
        end,
        desc = "debug toggle breakpoint",
      },
      {
        "<leader>dB",
        function()
          require("debugger").conditional_breakpoint()
        end,
        desc = "debug conditional breakpoint",
      },
      {
        "<leader>dc",
        function()
          require("debugger").continue()
        end,
        desc = "debug continue",
      },
      {
        "<leader>dq",
        function()
          require("debugger").stop()
        end,
        desc = "debug stop",
      },
      {
        "<leader>du",
        function()
          require("debugger").toggle_ui()
        end,
        desc = "debug show or hide panels",
      },
      {
        "<leader>de",
        function()
          require("debugger").eval()
        end,
        mode = { "n", "x" },
        desc = "debug evaluate",
      },
    },
  },

  {
    "f-person/git-blame.nvim",
    event = "VeryLazy",
    opts = {
      enabled = true,
      message_template = " <summary> • <date> • <author> • <<sha>>",
      date_format = "%m-%d-%Y %H:%M:%S",
      virtual_text_column = 1,
    },
  },
}
