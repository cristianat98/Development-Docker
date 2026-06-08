# Python Execution

When installing dependencies or running any Python script, always use the `.venv` virtual environment present in the project folder (e.g., `.venv/bin/python`, `.venv/bin/pip`).

If `.venv` is not present in the folder, do not attempt to create it or install packages globally. Instead, stop and advise the user that `.venv` is not present and ask them to create it before proceeding.
