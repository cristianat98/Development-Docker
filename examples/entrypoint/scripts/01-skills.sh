#!/bin/bash

wget https://github.com/lugasia/3gpp-skill/releases/download/v1.1.0/3gpp-expert.skill
mkdir 3gpp
mv 3gpp-expert.skill 3gpp/
cd 3gpp
unzip 3gpp-expert.skill
mkdir -p ~/.claude/skills/3gpp-expert
mv SKILL.md references ~/.claude/skills/3gpp-expert/
cd ..
rm -rf 3gpp
