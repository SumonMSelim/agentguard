class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v1.5.1.tar.gz"
  sha256 "3d36027d8e90a2c8389189ff7f8bbe58d52e35065af18440ab8ef1068226a611"
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
    bash = Formula["bash"].opt_bin/"bash"
    assert_match "Unknown agent", shell_output("#{bash} #{libexec}/install.sh __test__ 2>&1", 1)
    assert_match version.to_s, shell_output("#{bash} #{libexec}/install.sh version 2>&1")
  end
end
