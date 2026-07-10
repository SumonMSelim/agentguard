class Agentguard < Formula
  desc "Security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex)"
  homepage "https://github.com/SumonMSelim/agentguard"
  url "https://github.com/SumonMSelim/agentguard/archive/refs/tags/v2.1.1.tar.gz"
  sha256 "32f21f24ae17bf6a634dabbb04baade26362163ae69ae311459ef19ec1ec05bd"
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

  def post_install
    config_file = "#{Dir.home}/.agentguard/config"
    return unless File.exist?(config_file)

    line = File.readlines(config_file).reverse.find { |l| l.start_with?("AGENTGUARD_INSTALLED_AGENTS=") }
    return unless line

    agents = line.sub("AGENTGUARD_INSTALLED_AGENTS=", "").strip.delete_prefix('"').delete_suffix('"').split
    agents.each do |agent|
      system bin/"agentguard", "uninstall", agent
      system bin/"agentguard", agent
    end
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
