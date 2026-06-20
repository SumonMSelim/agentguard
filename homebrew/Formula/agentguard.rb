class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v1.9.0.tar.gz"
  sha256 "3376a3c4e1f98e7268bcaa02ffc19d822b05873d1f4145442e00f3aa581c2de1"
  license "MIT"

  depends_on "bash" => [:runtime, :test]
  depends_on "jq"

  def install
    # Install only runtime files — exclude tests/, packaging/, .github/
    libexec.install "hooks", "agents", "skills", "install.sh", "VERSION"

    # Wrapper invokes Homebrew bash 5 via its keg-only opt path.
    # Using HOMEBREW_PREFIX/opt/bash avoids both the Formula["bash"] static
    # analyser false-positive and the prefix/bin absence (bash is keg-only).
    homebrew_bash = "#{HOMEBREW_PREFIX}/opt/bash/bin/bash"
    (bin/"agentguard").write <<~SH
      #!/bin/bash
      exec "#{homebrew_bash}" "#{libexec}/install.sh" "$@"
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
