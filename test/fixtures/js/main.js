// Handlers used by test/fixtures/nginx.conf (njs module parity checks).
function hello(r) {
    r.return(200, "njs " + njs.version + "\n");
}

function body_size(r) {
    var body = r.requestBuffer;
    r.return(200, (body ? body.length : 0) + "\n");
}

export default { hello: hello, body_size: body_size };
