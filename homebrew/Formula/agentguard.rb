class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v2.1.4.tar.gz"
  sha256 "a7d89af13b76f7b61dc3a9fb5a7d4c2a868b8be4fbc63515f7b2a148ce084494"
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
