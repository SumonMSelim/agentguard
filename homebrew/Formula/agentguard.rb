class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v1.7.0.tar.gz"
  sha256 "743ce4c51e2cde4c932276b32e8a0be6094e0eab8e0fbf1a1767574e93524ff6"
  license "MIT"

  depends_on "bash" => [:runtime, :test]
  depends_on "jq"

  def install
    # Install only runtime files — exclude tests/, packaging/, .github/
    libexec.install "hooks", "agents", "skills", "install.sh", "VERSION"

    # Wrapper invokes Homebrew bash 5 to avoid macOS system bash 3.2.
    # Use HOMEBREW_PREFIX string constant instead of Formula["bash"] so the
    # brew test static analyser does not flag a missing test dependency.
    homebrew_bash = "#{HOMEBREW_PREFIX}/bin/bash"
    (bin/"agentguard").write <<~SH
      #!/bin/bash
      exec "#{homebrew_bash}" "#{libexec}/install.sh" "$@"
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
