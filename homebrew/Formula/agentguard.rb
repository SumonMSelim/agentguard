class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex, Grok, Gemini CLI, Copilot CLI, Windsurf, Antigravity CLI)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v3.0.0.tar.gz"
  sha256 "2a1ae48957d004c2a90774ea1ae44c88d5716836f2eb5fb57c204bf56392f78a"
  license "MIT"

  depends_on "jq"

  def install
    libexec.install "hooks", "agents", "skills", "install.sh", "VERSION"

    (bin/"agentguard").write <<~SH
      #!/usr/bin/env bash
      exec bash "#{libexec}/install.sh" "$@"
    SH
    chmod 0755, bin/"agentguard"
  end

  def caveats
    <<~EOS
      Run agentguard to install guardrails for your AI coding agent:

        agentguard claude        # Claude Code
        agentguard kiro          # Kiro
        agentguard cursor        # Cursor (run from project root)
        agentguard codex         # Codex
        agentguard grok          # Grok
        agentguard gemini        # Gemini CLI
        agentguard copilot       # GitHub Copilot CLI
        agentguard windsurf      # Windsurf (Cascade)
        agentguard antigravity   # Google Antigravity CLI (agy)
        agentguard all           # All agents

      Upgrade guardrails to the latest version:

        agentguard upgrade

      Check installation health:

        agentguard check claude
    EOS
  end

  test do
    assert_match "Unknown agent", shell_output("#{bin}/agentguard __test__ 2>&1", 1)
    assert_match version.to_s, shell_output("#{bin}/agentguard version 2>&1")
  end
end
