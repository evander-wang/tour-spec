-- pi-tour：把 agent 生成的 tour spec 渲染成 Neovim 里可以「走」的链路导览
-- 放在 ~/.config/nvim/lua/plugins/pi-tour.lua（本仓库里的这份是权威副本，建议 symlink 过去）
-- 插件本体在 ~/.pi/agent/tours/nvim/lua/pi_tour/init.lua（和 HTML 版共用一份 spec）
-- 快捷键：F9 / F10 步进（单键），]T / [T 也保留，<leader>Tt 站点列表，<leader>To 切换导览（多份 spec 并存时选一份），
--         <leader>Ts 结束，<leader>Tr 重载
-- 为什么加 F9/F10：]T 是双键前缀，timeoutlen=300 时稍慢一点 `]` 就会单独触发，几乎按不出来。
-- 仓库克隆到别处时，改下面这一个 dir 即可。
return {
  {
    dir = vim.fn.expand("~/.pi/agent/tours/nvim"),
    name = "pi-tour",
    lazy = false,
    config = function()
      require("pi_tour").setup()
      -- 单键别名：不受 timeoutlen 影响
      vim.keymap.set("n", "<F9>", function()
        require("pi_tour").next()
      end, { desc = "tour: 下一站" })
      vim.keymap.set("n", "<F10>", function()
        require("pi_tour").prev()
      end, { desc = "tour: 上一站" })
    end,
  },
}
