module main

import crypto.sha256
import time

[table: 'users']
struct User {
    id           int       [primary; sql: serial]
    email        string    [nonull]
    password     string    [nonull]
    created_date time.Time [nonull]
}

fn hash_password(password string, salt string) string {
	salted := '${password}${salt}'
	return sha256.sum(salted.bytes()).hex().str()
}

fn (mut app App) register_new_user(email string, password string) !int {
    hashed_password := hash_password(password, app.salt)
    user := User{
        email: email
        password: hashed_password
        created_date: time.utc()
    }

    user_exists := sql app.user_db {
        select from User where email == email limit 1
    }
    if user_exists.id > 0 {
        return error('User already exists!')
    }

    sql app.user_db {
        insert user into User
    }
    id := app.user_db.last_id()
    return id
}

fn (mut app App) get_user_id(email string, password string) int {
    hashed_password := hash_password(password, app.salt)
    result := sql app.user_db {
        select from User
        where password == hashed_password && email == email
        limit 1
    }
    return result.id
}

