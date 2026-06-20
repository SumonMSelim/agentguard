class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v2.0.1.tar.gz"
  sha256 "40d601ef4bbc7cb554680be05fcc2b7434dc751e2ec6c7a52f6269b2ae206fac"
  license "MIT"

  depends_on "bash" => [:build, :runtime, :test]
  depends_on "jq"

  def install
    libexec.install "hooks", "agents", "skills", "install.sh", "VERSION"

    # Formula["bash"].opt_bin resolves to the keg-only Homebrew bash — the
    # correct idiom for referencing a dep's bin on both macOS and Linux.
    # Homebrew guarantees this path exists because bash is a declared dep.
    bash = Formula["bash"].opt_bin/"bash"
    (bin/"agentguard").write <<~SH
      #!/bin/bash
      exec "#{bash}" "#{libexec}/install.sh" "$@"
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
