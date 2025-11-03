#!/bin/bash

# Default values
DEBUG_MODE=false
env="local"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --debug) DEBUG_MODE=true ;;
        --env) env="$2"; shift ;;
        --help) 
            echo "Usage: $0 [--debug] [--env <environment>]"
            exit 0
            ;;
        *) 
            echo "Unknown parameter passed: $1"
            echo "Usage: $0 [--debug] [--env <environment>]"
            exit 1
            ;;
    esac
    shift
done

login() {
    hurl --test --variables-file "$env.env" --cookie-jar ./cookie-jar.tsv ./login.hurl 
}

run_with_cookies() {
    # If debug mode then add argument "--error-format long"
    if [ "$DEBUG_MODE" = true ]; then
        hurl --test --jobs 1 --variables-file "$env.env" --cookie ./cookie-jar.tsv \
            --error-format long "${@:1}" --verbose
    else
        hurl --test --jobs 1 --variables-file "$env.env" --cookie ./cookie-jar.tsv "${@:1}"
    fi
}

test_dir=$(mktemp -d --tmpdir)
app_path="$test_dir/app"
port=12382
static_files="$test_dir/static"
kill_key="test_kill_key"

cat > "$test_dir/config.json" << EOF
{
    "appPath":"$app_path",
    "port": $port,
    "staticFiles": "$static_files",
    "killKey": "$kill_key"
}
EOF

mkdir $static_files

v -o "$test_dir/ImageBase" .
"$test_dir/ImageBase" --config "$test_dir/config.json" &
app_pid=$!

sleep 0.1

cd ./tests

rm cookie-jar.tsv 2> /dev/null || true

run_with_cookies \
    ./unauthorized.tests.hurl \
    ./invalid-register.tests.hurl \
    ./register-user.tests.hurl \
    ./invalid-login.tests.hurl

login

run_with_cookies \
    ./add-data.tests.hurl \
    ./logout.tests.hurl \
    ./forgot-password.tests.hurl

result=$(sqlite3 "$app_path/sessions.db" << EOF
.mode column
.headers on
SELECT * FROM password_reset;
EOF
)

echo "Password Reset (should have one entry):
$result"

# Get the reset token from the database
reset_token=$(sqlite3 "$app_path/sessions.db" << EOF
.mode column
.headers off
SELECT token FROM password_reset LIMIT 1;
EOF
)

hurl --test --jobs 1 --variable reset_token="$reset_token" \
    --variables-file "$env.env" --cookie ./cookie-jar.tsv ./create-new-password.tests.hurl

# The reset table should now be empty
result=$(sqlite3 "$app_path/sessions.db" << EOF
.mode column
.headers on
SELECT * FROM password_reset;
EOF
)

echo "Password Reset (should be empty): ($result)"

echo "
$app_path
"

kill $app_pid

cd -

# login
# run_with_cookies \
#     ./clean-db.hurl \
#     ./login-page.tests.hurl \
#     ./not-logged-in-redirects.tests.hurl
# login
# run_with_cookies \
#     ./category.tests.hurl \
#     ./transaction.tests.hurl \
#     ./transaction-htmf.tests.hurl \
#     ./export.tests.hurl \
#     ./settings.tests.hurl \
#     ./logout.tests.hurl

# cd -
