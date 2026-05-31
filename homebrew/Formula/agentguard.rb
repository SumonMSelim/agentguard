class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "38c22e326ecc731730f15ea97932d4c382a3ddf7dfc578bbf4646408b7b22101"
  license "MIT"

  depends_on "bash"
  depends_on "jq"

  def install
    # Install only runtime files — exclude tests/, packaging/, .github/
    libexec.install "hooks", "agents", "skills", "install.sh", "VERSION"

    # Wrapper uses Homebrew bash explicitly — avoids macOS system bash 3.2
    (bin/"agentguard").write <<~SH
      #!/usr/bin/env bash
      exec "#{Formula["bash"].opt_bin}/bash" "#{libexec}/install.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      Run agentguard to install guardrails for your AI coding agent:

        agentguard claude        # Claude Code
        agentguard kiro          # Kiro
        agentguard cursor        # Cursor (run from project root)
        agentguard codex         # Codex
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
