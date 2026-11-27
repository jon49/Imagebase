// Process-wide settings. Set once in main before any worker starts; each
// worker gets its own copy at spawn (Goose threads share nothing), which is
// why everything here is flat, fixed-size data.

struct Config {
    data_dir: u8[..1024],
    address: u8[..256],
    site_url: u8[..512],
    sendmail: u8[..256],
    mail_from: u8[..256],
    app_name: u8[..64],
    cors_origin: u8[..512],     // "*" echoes any Origin; "" sends no CORS headers
    dev: bool,
    access_log: bool,
    workers: i64,
    auth_ttl: i64,
    refresh_ttl: i64,
}

var CFG: Config;
var JWT_KEY: u8[32];
