#!/bin/bash

# RTK
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
printf 'n\n' | rtk init -g --auto-patch

# NLM
pipx install --force notebooklm-mcp-cli
/root/.local/bin/nlm setup add claude-code
echo "Login in NotebookLM CLI: nlm login"

# CTX7
npm install -g ctx7
if [[ -n "$CONTEXT7_API_KEY" ]]; then
    # npx ctx7 setup --claude --cli --api-key "$CONTEXT7_API_KEY" --yes
    claude mcp add --scope user --transport http \
        context7 \
        https://mcp.context7.com/mcp \
        -H "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}"
fi

# Skills
wget https://github.com/lugasia/3gpp-skill/releases/download/v1.1.0/3gpp-expert.skill
mkdir 3gpp
mv 3gpp-expert.skill 3gpp/
cd 3gpp
unzip 3gpp-expert.skill
mkdir -p ~/.claude/skills/3gpp-expert
mv SKILL.md references ~/.claude/skills/3gpp-expert/
cd ..
rm -rf 3gpp

echo "Login in Claude CLI"
echo "Login in Notion"
echo "Login in Atlassian"
echo "Login in Microsoft"
