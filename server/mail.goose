// Outgoing mail. Messages are piped to `sendmail -t -i` (msmtp, postfix and
// exim all provide it; configure delivery there). In --dev mode they are
// written to stderr instead, which is how the tests read reset codes.
import std;
import .util;
import .config;

// `body` is an HTML document.
fn send_mail(to: const u8[:], subject: const u8[:], body: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, "From: ", CFG.mail_from, "\nTo: ", to, "\nSubject: ", subject,
           "\nMIME-Version: 1.0\nContent-Type: text/html; charset=utf-8\n\n", body);
    if CFG.dev {
        log(str("[dev] Skip sending email to ", to, ":\n", msg));
        return;
    }
    if !ib_sendmail(CFG.sendmail, msg) { log(str("mail to ", to, " failed (", CFG.sendmail, ")")); }
}
