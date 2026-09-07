pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("pip_gtk.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});
