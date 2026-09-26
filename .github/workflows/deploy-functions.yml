name: Deploy Vidya Saarthi Push Function

on:
  push:
    branches:
      - main
    paths:
      - 'functions/**'
      - '.github/workflows/deploy-functions.yml'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Node 22
        uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Install Function Dependencies
        working-directory: functions
        run: npm install --omit=dev

      - name: Install Firebase CLI
        run: npm install -g firebase-tools

      - name: Configure Firebase Credentials
        shell: bash
        env:
          FIREBASE_SERVICE_ACCOUNT: ${{ secrets.FIREBASE_SERVICE_ACCOUNT }}
        run: |
          set -euo pipefail

          if [ -z "$FIREBASE_SERVICE_ACCOUNT" ]; then
            echo "::error::FIREBASE_SERVICE_ACCOUNT secret missing."
            exit 1
          fi

          printf '%s' "$FIREBASE_SERVICE_ACCOUNT" \
            > "$RUNNER_TEMP/firebase-service-account.json"

          echo "GOOGLE_APPLICATION_CREDENTIALS=$RUNNER_TEMP/firebase-service-account.json" \
            >> "$GITHUB_ENV"

      - name: Create Functions-only Firebase Config
        shell: bash
        run: |
          cat > firebase.functions.ci.json <<'JSON'
          {
            "functions": [
              {
                "source": "functions",
                "codebase": "default"
              }
            ]
          }
          JSON

      - name: Deploy Push Function
        run: |
          firebase deploy \
            --project saarthi-ai-df12b \
            --only functions \
            --config firebase.functions.ci.json \
            --non-interactive

      - name: Cleanup Credential File
        if: always()
        run: rm -f "$RUNNER_TEMP/firebase-service-account.json"
