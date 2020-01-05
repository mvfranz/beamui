/**
This module contains drawing buffer implementation.

Copyright: Vadim Lopatin 2014-2017, dayllenger 2017-2018
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.graphics.drawbuf;

public import beamui.core.geometry;
public import beamui.core.types;
import std.math;
import beamui.core.collections : Buf;
import beamui.core.config;
import beamui.core.functions;
import beamui.core.linalg;
import beamui.core.logger;
import beamui.core.math;
import beamui.graphics.colors;
import beamui.text.glyph : GlyphRef, SubpixelRenderingMode;

/// 9-patch image scaling information (unscaled frame and scaled middle parts)
struct NinePatch
{
    /// Frame (non-scalable) part size for left, top, right, bottom edges.
    InsetsI frame;
    /// Padding (distance to content area) for left, top, right, bottom edges.
    InsetsI padding;
}

enum PatternType : uint
{
    solid,
    dotted,
}

/// Positioned glyph
struct GlyphInstance
{
    GlyphRef glyph;
    Point position;
}

static if (USE_OPENGL)
{
    /// Non thread safe
    private __gshared uint drawBufIDGenerator = 0;
}

/// Custom draw delegate for OpenGL direct drawing
alias DrawHandler = void delegate(Rect windowRect, Rect rc);

/// Drawing buffer - image container which allows to perform some drawing operations
class DrawBuf : RefCountedObject
{
    @property
    {
        /// Image buffer bits per pixel value
        abstract int bpp() const;
        /// Image width
        abstract int width() const;
        /// Image height
        abstract int height() const;

        /// Nine-patch info pointer, `null` if this is not a nine patch image buffer
        const(NinePatch)* ninePatch() const { return _ninePatch; }
        /// ditto
        void ninePatch(NinePatch* ninePatch)
        {
            _ninePatch = ninePatch;
        }
        /// Check whether there is nine-patch information available
        bool hasNinePatch() const
        {
            return _ninePatch !is null;
        }
    }

    private Rect _clipRect;
    private NinePatch* _ninePatch;
    private uint _alpha = 255;

    static if (USE_OPENGL)
    {
        private uint _id;
        /// Unique ID of drawbuf instance, for using with hardware accelerated rendering for caching
        @property uint id() const { return _id; }
    }

    debug static
    {
        private __gshared int _instanceCount;
        int instanceCount() { return _instanceCount; }
    }

    this()
    {
        static if (USE_OPENGL)
        {
            _id = drawBufIDGenerator++;
        }
        debug _instanceCount++;
    }

    ~this()
    {
        debug
        {
            if (APP_IS_SHUTTING_DOWN)
                onResourceDestroyWhileShutdown("drawbuf", getShortClassName(this));
            _instanceCount--;
        }
        clear();
    }

    void function(uint) onDestroyCallback;

    /// Call to remove this image from OpenGL cache when image is updated.
    void invalidate()
    {
        static if (USE_OPENGL)
        {
            if (onDestroyCallback)
            {
                // remove from cache
                onDestroyCallback(_id);
                // assign new ID
                _id = drawBufIDGenerator++;
            }
        }
    }

    /// Resize the image buffer, invalidating its content
    abstract void resize(int width, int height);

    void clear()
    {
        resetClipping();
    }

    /// Current alpha setting (applied to all drawing operations)
    @property uint alpha() const { return _alpha; }
    /// ditto
    @property void alpha(uint alpha)
    {
        _alpha = min(alpha, 0xFF);
    }

    /// Apply additional transparency to current drawbuf alpha value
    void addAlpha(uint alpha)
    {
        _alpha = blendAlpha(_alpha, alpha);
    }

    /// Applies current drawbuf alpha to color
    void applyAlpha(ref Color c)
    {
        c.addAlpha(_alpha);
    }

    /// Detect nine patch using image 1-pixel border. Returns true if 9-patch markup is found in the image
    bool detectNinePatch()
    {
        // override
        return false;
    }

    //===============================================================
    // Clipping rectangle functions

    /// Init clip rectangle to full buffer size
    void resetClipping()
    {
        _clipRect = Rect(0, 0, width, height);
    }

    @property bool hasClipping() const
    {
        return _clipRect.left != 0 || _clipRect.top != 0 || _clipRect.right != width || _clipRect.bottom != height;
    }
    /// Clipping rectangle
    @property ref const(Rect) clipRect() const { return _clipRect; }
    /// ditto
    @property void clipRect(const ref Rect rc)
    {
        _clipRect = rc;
        _clipRect.intersect(Rect(0, 0, width, height));
    }
    /// Set new clipping rectangle, intersect with previous one
    void intersectClipRect(const ref Rect rc)
    {
        _clipRect.intersect(rc);
    }
    /// Returns true if rectangle is completely clipped out and cannot be drawn.
    @property bool isClippedOut(const ref Rect rc) const
    {
        return !_clipRect.intersects(rc);
    }
    /// Apply `clipRect` and buffer bounds clipping to rectangle
    bool applyClipping(ref Rect rc) const
    {
        rc.intersect(_clipRect);
        if (rc.left < 0)
            rc.left = 0;
        if (rc.top < 0)
            rc.top = 0;
        if (rc.right > width)
            rc.right = width;
        if (rc.bottom > height)
            rc.bottom = height;
        return !rc.empty;
    }
    /// Apply `clipRect` and buffer bounds clipping to rectangle
    /// If clipping applied to first rectangle, reduce second rectangle bounds proportionally
    bool applyClipping(ref Rect rc, ref Rect rc2) const
    {
        if (rc.empty || rc2.empty)
            return false;
        if (!rc.intersects(_clipRect))
            return false;
        if (rc.width == rc2.width && rc.height == rc2.height)
        {
            // unscaled
            if (rc.left < _clipRect.left)
            {
                rc2.left += _clipRect.left - rc.left;
                rc.left = _clipRect.left;
            }
            if (rc.top < _clipRect.top)
            {
                rc2.top += _clipRect.top - rc.top;
                rc.top = _clipRect.top;
            }
            if (rc.right > _clipRect.right)
            {
                rc2.right -= rc.right - _clipRect.right;
                rc.right = _clipRect.right;
            }
            if (rc.bottom > _clipRect.bottom)
            {
                rc2.bottom -= rc.bottom - _clipRect.bottom;
                rc.bottom = _clipRect.bottom;
            }
            if (rc.left < 0)
            {
                rc2.left += -rc.left;
                rc.left = 0;
            }
            if (rc.top < 0)
            {
                rc2.top += -rc.top;
                rc.top = 0;
            }
            if (rc.right > width)
            {
                rc2.right -= rc.right - width;
                rc.right = width;
            }
            if (rc.bottom > height)
            {
                rc2.bottom -= rc.bottom - height;
                rc.bottom = height;
            }
        }
        else
        {
            // scaled
            int dstdx = rc.width;
            int dstdy = rc.height;
            int srcdx = rc2.width;
            int srcdy = rc2.height;
            if (rc.left < _clipRect.left)
            {
                rc2.left += (_clipRect.left - rc.left) * srcdx / dstdx;
                rc.left = _clipRect.left;
            }
            if (rc.top < _clipRect.top)
            {
                rc2.top += (_clipRect.top - rc.top) * srcdy / dstdy;
                rc.top = _clipRect.top;
            }
            if (rc.right > _clipRect.right)
            {
                rc2.right -= (rc.right - _clipRect.right) * srcdx / dstdx;
                rc.right = _clipRect.right;
            }
            if (rc.bottom > _clipRect.bottom)
            {
                rc2.bottom -= (rc.bottom - _clipRect.bottom) * srcdy / dstdy;
                rc.bottom = _clipRect.bottom;
            }
            if (rc.left < 0)
            {
                rc2.left -= (rc.left) * srcdx / dstdx;
                rc.left = 0;
            }
            if (rc.top < 0)
            {
                rc2.top -= (rc.top) * srcdy / dstdy;
                rc.top = 0;
            }
            if (rc.right > width)
            {
                rc2.right -= (rc.right - width) * srcdx / dstdx;
                rc.right = width;
            }
            if (rc.bottom > height)
            {
                rc2.bottom -= (rc.bottom - height) * srcdx / dstdx;
                rc.bottom = height;
            }
        }
        return !rc.empty && !rc2.empty;
    }
    /// Reserved for hardware-accelerated drawing - begins drawing batch
    void beforeDrawing()
    {
        _alpha = 255;
    }
    /// Reserved for hardware-accelerated drawing - ends drawing batch
    void afterDrawing()
    {
    }

    //========================================================
    // Drawing methods

    /// Fill the whole buffer with solid color (no clipping applied)
    abstract void fill(Color color);
    /// Fill rectangle with solid color (clipping is applied)
    abstract void fillRect(Rect rc, Color color);
    /// Fill rectangle with a gradient (clipping is applied)
    abstract void fillGradientRect(Rect rc, Color color1, Color color2, Color color3, Color color4);

    /// Fill rectangle with solid color and pattern (clipping is applied)
    void fillRectPattern(Rect rc, Color color, PatternType pattern)
    {
    }
    /// Draw pixel at (x, y) with specified color (clipping is applied)
    abstract void drawPixel(int x, int y, Color color);
    /// Draw 8bit alpha image - usually font glyph using specified color (clipping is applied)
    abstract void drawGlyph(int x, int y, GlyphRef glyph, Color color);
    /// Draw source buffer rectangle contents to destination buffer (clipping is applied)
    abstract void drawFragment(int x, int y, DrawBuf src, Rect srcrect);
    /// Draw source buffer rectangle contents to destination buffer rectangle applying rescaling
    abstract void drawRescaled(Rect dstrect, DrawBuf src, Rect srcrect);

    /// Draw unscaled image at specified coordinates
    void drawImage(int x, int y, DrawBuf src)
    {
        drawFragment(x, y, src, Rect(0, 0, src.width, src.height));
    }

    /// Draw custom OpenGL scene
    void drawCustomOpenGLScene(Rect rc, DrawHandler handler)
    {
        // override it for OpenGL draw buffer
        Log.w("drawCustomOpenGLScene is called for non-OpenGL DrawBuf");
    }
}

alias DrawBufRef = Ref!DrawBuf;

/// RAII setting/restoring of a DrawBuf clip rectangle
struct ClipRectSaver
{
    private DrawBuf _buf;
    private Rect _oldClipRect;
    private uint _oldAlpha;

    /// Intersect new clip rectangle and apply alpha to draw buf
    this(DrawBuf buf, Rect newClipRect, uint newAlpha = 255)
    {
        _buf = buf;
        _oldClipRect = buf.clipRect;
        _oldAlpha = buf.alpha;

        buf.intersectClipRect(newClipRect);
        if (newAlpha < 255)
            buf.addAlpha(newAlpha);
    }
    /// ditto
    this(DrawBuf buf, Box newClipBox, uint newAlpha = 255)
    {
        this(buf, Rect(newClipBox), newAlpha);
    }
    /// Restore previous clip rectangle
    ~this()
    {
        _buf.clipRect = _oldClipRect;
        _buf.alpha = _oldAlpha;
    }
}

class ColorDrawBufBase : DrawBuf
{
    override @property
    {
        int bpp() const { return 32; }
        int width() const { return _w; }
        int height() const { return _h; }
    }

    protected int _w;
    protected int _h;

    /// Returns pointer to ARGB scanline, `null` if `y` is out of range or buffer doesn't provide access to its memory
    inout(uint*) scanLine(int y) inout
    {
        return null;
    }

    override void drawFragment(int x, int y, DrawBuf src, Rect srcrect)
    {
        auto img = cast(ColorDrawBufBase)src;
        if (!img)
            return;
        Rect dstrect = Rect(x, y, x + srcrect.width, y + srcrect.height);
        if (applyClipping(dstrect, srcrect))
        {
            if (src.applyClipping(srcrect, dstrect))
            {
                const int dx = srcrect.width;
                const int dy = srcrect.height;
                foreach (yy; 0 .. dy)
                {
                    uint* srcrow = img.scanLine(srcrect.top + yy) + srcrect.left;
                    uint* dstrow = scanLine(dstrect.top + yy) + dstrect.left;
                    if (_alpha == 255)
                    {
                        // simplified version - no alpha blending
                        foreach (i; 0 .. dx)
                        {
                            const uint pixel = srcrow[i];
                            const uint alpha = pixel >> 24;
                            if (alpha == 255)
                            {
                                dstrow[i] = pixel;
                            }
                            else if (alpha > 0)
                            {
                                // apply blending
                                blendARGB(dstrow[i], pixel, alpha);
                            }
                        }
                    }
                    else
                    {
                        // combine two alphas
                        foreach (i; 0 .. dx)
                        {
                            const uint pixel = srcrow[i];
                            const uint alpha = blendAlpha(_alpha, pixel >> 24);
                            if (alpha == 255)
                            {
                                dstrow[i] = pixel;
                            }
                            else if (alpha > 0)
                            {
                                // apply blending
                                blendARGB(dstrow[i], pixel, alpha);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Create mapping of source coordinates to destination coordinates, for resize.
    private Buf!int createMap(int dst0, int dst1, int src0, int src1, double k)
    {
        const dd = dst1 - dst0;
        //int sd = src1 - src0;
        Buf!int ret;
        ret.reserve(dd);
        foreach (int i; 0 .. dd)
            ret ~= src0 + cast(int)(i * k); //sd / dd;
        return ret;
    }

    override void drawRescaled(Rect dstrect, DrawBuf src, Rect srcrect)
    {
        if (_alpha == 0)
            return; // fully transparent - don't draw
        auto img = cast(ColorDrawBufBase)src;
        if (!img)
            return;
        double kx = cast(double)srcrect.width / dstrect.width;
        double ky = cast(double)srcrect.height / dstrect.height;
        if (applyClipping(dstrect, srcrect))
        {
            auto xmapArray = createMap(dstrect.left, dstrect.right, srcrect.left, srcrect.right, kx);
            auto ymapArray = createMap(dstrect.top, dstrect.bottom, srcrect.top, srcrect.bottom, ky);
            int* xmap = xmapArray.unsafe_ptr;
            int* ymap = ymapArray.unsafe_ptr;

            const int dx = dstrect.width;
            const int dy = dstrect.height;
            foreach (y; 0 .. dy)
            {
                uint* srcrow = img.scanLine(ymap[y]);
                uint* dstrow = scanLine(dstrect.top + y) + dstrect.left;
                if (_alpha == 255)
                {
                    // simplified alpha calculation
                    foreach (x; 0 .. dx)
                    {
                        const uint srcpixel = srcrow[xmap[x]];
                        const uint alpha = srcpixel >> 24;
                        if (alpha == 255)
                        {
                            dstrow[x] = srcpixel;
                        }
                        else if (alpha > 0)
                        {
                            // apply blending
                            blendARGB(dstrow[x], srcpixel, alpha);
                        }
                    }
                }
                else
                {
                    // blending two alphas
                    foreach (x; 0 .. dx)
                    {
                        const uint srcpixel = srcrow[xmap[x]];
                        const uint alpha = blendAlpha(_alpha, srcpixel >> 24);
                        if (alpha == 255)
                        {
                            dstrow[x] = srcpixel;
                        }
                        else if (alpha > 0)
                        {
                            // apply blending
                            blendARGB(dstrow[x], srcpixel, alpha);
                        }
                    }
                }
            }
        }
    }

    /// Detect position of black pixels in row for 9-patch markup
    private bool detectHLine(int y, ref int x0, ref int x1)
    {
        uint* line = scanLine(y);
        bool foundUsed = false;
        x0 = 0;
        x1 = 0;
        foreach (int x; 1 .. _w - 1)
        {
            if (isBlackPixel(line[x]))
            { // opaque black pixel
                if (!foundUsed)
                {
                    x0 = x;
                    foundUsed = true;
                }
                x1 = x + 1;
            }
        }
        return x1 > x0;
    }

    static bool isBlackPixel(uint pixel)
    {
        const c = Color.fromPacked(pixel);
        return c.r < 10 && c.g < 10 && c.b < 10 && c.a > 245;
    }

    /// Detect position of black pixels in column for 9-patch markup
    private bool detectVLine(int x, ref int y0, ref int y1)
    {
        bool foundUsed;
        y0 = 0;
        y1 = 0;
        foreach (int y; 1 .. _h - 1)
        {
            uint* line = scanLine(y);
            if (isBlackPixel(line[x]))
            { // opaque black pixel
                if (!foundUsed)
                {
                    y0 = y;
                    foundUsed = true;
                }
                y1 = y + 1;
            }
        }
        return y1 > y0;
    }
    /// Detect nine patch using image 1-pixel border (see Android documentation)
    override bool detectNinePatch()
    {
        if (_w < 3 || _h < 3)
            return false; // image is too small
        int x00, x01, x10, x11, y00, y01, y10, y11;
        bool found = true;
        found = found && detectHLine(0, x00, x01);
        found = found && detectHLine(_h - 1, x10, x11);
        found = found && detectVLine(0, y00, y01);
        found = found && detectVLine(_w - 1, y10, y11);
        if (!found)
            return false; // no black pixels on 1-pixel frame
        NinePatch* p = new NinePatch;
        p.frame.left = x00 - 1;
        p.frame.right = _w - x01 - 1;
        p.frame.top = y00 - 1;
        p.frame.bottom = _h - y01 - 1;
        p.padding.left = x10 - 1;
        p.padding.right = _w - x11 - 1;
        p.padding.top = y10 - 1;
        p.padding.bottom = _h - y11 - 1;
        _ninePatch = p;
        return true;
    }

    override void drawGlyph(int x, int y, GlyphRef glyph, Color color)
    {
        applyAlpha(color);
        const uint rgb = color.rgb;
        immutable(ubyte[]) src = glyph.glyph;
        const int srcdx = glyph.blackBoxX;
        const int srcdy = glyph.blackBoxY;
        const bool clipping = true; //!_clipRect.empty();
        const bool subpixel = glyph.subpixelMode != SubpixelRenderingMode.none;
        foreach (int yy; 0 .. srcdy)
        {
            const int liney = y + yy;
            if (clipping && (liney < _clipRect.top || liney >= _clipRect.bottom))
                continue;
            if (liney < 0 || liney >= _h)
                continue;

            uint* row = scanLine(liney);
            immutable(ubyte*) srcrow = src.ptr + yy * srcdx;
            foreach (int xx; 0 .. srcdx)
            {
                int colx = x + (subpixel ? xx / 3 : xx);
                if (clipping && (colx < _clipRect.left || colx >= _clipRect.right))
                    continue;
                if (colx < 0 || colx >= _w)
                    continue;

                const uint alpha = blendAlpha(color.a, srcrow[xx]);
                if (subpixel)
                {
                    blendSubpixel(row[colx], rgb, alpha, xx % 3, glyph.subpixelMode);
                }
                else
                {
                    if (alpha == 255)
                    {
                        row[colx] = rgb;
                    }
                    else if (alpha > 0)
                    {
                        // apply blending
                        blendARGB(row[colx], rgb, alpha);
                    }
                }
            }
        }
    }

    void drawGlyphToTexture(int x, int y, GlyphRef glyph)
    {
        immutable(ubyte[]) src = glyph.glyph;
        int srcdx = glyph.blackBoxX;
        int srcdy = glyph.blackBoxY;
        bool subpixel = glyph.subpixelMode != SubpixelRenderingMode.none;
        foreach (int yy; 0 .. srcdy)
        {
            int liney = y + yy;
            uint* row = scanLine(liney);
            immutable(ubyte*) srcrow = src.ptr + yy * srcdx;
            int increment = subpixel ? 3 : 1;
            for (int xx = 0; xx <= srcdx - increment; xx += increment)
            {
                int colx = x + (subpixel ? xx / 3 : xx);
                if (subpixel)
                {
                    uint t1 = srcrow[xx];
                    uint t2 = srcrow[xx + 1];
                    uint t3 = srcrow[xx + 2];
                    //uint pixel = ((t2 ^ 0x00) << 24) | ((t1  ^ 0xFF)<< 16) | ((t2 ^ 0xFF) << 8) | (t3 ^ 0xFF);
                    uint pixel = ((t2 ^ 0x00) << 24) | 0xFFFFFF;
                    row[colx] = pixel;
                }
                else
                {
                    uint alpha1 = srcrow[xx] ^ 0xFF;
                    //uint pixel = (alpha1 << 24) | 0xFFFFFF; //(alpha1 << 16) || (alpha1 << 8) || alpha1;
                    //uint pixel = ((alpha1 ^ 0xFF) << 24) | (alpha1 << 16) | (alpha1 << 8) | alpha1;
                    uint pixel = ((alpha1 ^ 0xFF) << 24) | 0xFFFFFF;
                    row[colx] = pixel;
                }
            }
        }
    }

    override void fillRect(Rect rc, Color color)
    {
        applyAlpha(color);
        if (!color.isFullyTransparent && applyClipping(rc))
        {
            const bool opaque = color.isOpaque;
            const uint rgb = color.rgb;
            foreach (y; rc.top .. rc.bottom)
            {
                uint* row = scanLine(y);
                if (opaque)
                {
                    row[rc.left .. rc.right] = rgb;
                }
                else
                {
                    foreach (x; rc.left .. rc.right)
                    {
                        // apply blending
                        blendARGB(row[x], rgb, color.a);
                    }
                }
            }
        }
    }

    override void fillGradientRect(Rect rc, Color color1, Color color2, Color color3, Color color4)
    {
        if (applyClipping(rc))
        {
            foreach (y; rc.top .. rc.bottom)
            {
                // interpolate vertically at the side edges
                const double ay = (y - rc.top) / cast(double)(rc.bottom - rc.top);
                const cl = Color.mix(color1, color2, ay);
                const cr = Color.mix(color3, color4, ay);

                uint* row = scanLine(y);
                foreach (x; rc.left .. rc.right)
                {
                    // interpolate horizontally
                    const double ax = (x - rc.left) / cast(double)(rc.right - rc.left);
                    row[x] = Color.mix(cl, cr, ax).rgba;
                }
            }
        }
    }

    override void drawPixel(int x, int y, Color color)
    {
        if (!_clipRect.contains(x, y))
            return;

        applyAlpha(color);
        uint* row = scanLine(y);
        if (color.isOpaque)
        {
            row[x] = color.rgba;
        }
        else if (!color.isFullyTransparent)
        {
            // apply blending
            blendARGB(row[x], color.rgb, color.a);
        }
    }
}

class GrayDrawBuf : DrawBuf
{
    override @property
    {
        int bpp() const { return 8; }
        int width() const { return _w; }
        int height() const { return _h; }
    }

    private int _w;
    private int _h;
    private Buf!ubyte _buf;

    this(int width, int height)
    {
        resize(width, height);
    }

    ubyte* scanLine(int y)
    {
        if (y >= 0 && y < _h)
            return _buf.unsafe_ptr + _w * y;
        return null;
    }

    override void resize(int width, int height)
    {
        if (_w == width && _h == height)
            return;
        _w = width;
        _h = height;
        _buf.resize(_w * _h);
        resetClipping();
    }

    override void fill(Color color)
    {
        if (hasClipping)
            fillRect(Rect(0, 0, _w, _h), color);
        else
            _buf.unsafe_slice[] = color.toGray;
    }

    override void drawFragment(int x, int y, DrawBuf src, Rect srcrect)
    {
        auto img = cast(GrayDrawBuf)src;
        if (!img)
            return;
        Rect dstrect = Rect(x, y, x + srcrect.width, y + srcrect.height);
        if (applyClipping(dstrect, srcrect))
        {
            if (src.applyClipping(srcrect, dstrect))
            {
                const int dx = srcrect.width;
                const int dy = srcrect.height;
                foreach (yy; 0 .. dy)
                {
                    ubyte* srcrow = img.scanLine(srcrect.top + yy) + srcrect.left;
                    ubyte* dstrow = scanLine(dstrect.top + yy) + dstrect.left;
                    dstrow[0 .. dx] = srcrow[0 .. dx];
                }
            }
        }
    }

    /// Create mapping of source coordinates to destination coordinates, for resize.
    private Buf!int createMap(int dst0, int dst1, int src0, int src1)
    {
        const dd = dst1 - dst0;
        const sd = src1 - src0;
        Buf!int ret;
        ret.reserve(dd);
        foreach (int i; 0 .. dd)
            ret ~= src0 + i * sd / dd;
        return ret;
    }

    override void drawRescaled(Rect dstrect, DrawBuf src, Rect srcrect)
    {
        auto img = cast(GrayDrawBuf)src;
        if (!img)
            return;
        if (applyClipping(dstrect, srcrect))
        {
            auto xmapArray = createMap(dstrect.left, dstrect.right, srcrect.left, srcrect.right);
            auto ymapArray = createMap(dstrect.top, dstrect.bottom, srcrect.top, srcrect.bottom);
            int* xmap = xmapArray.unsafe_ptr;
            int* ymap = ymapArray.unsafe_ptr;

            const int dx = dstrect.width;
            const int dy = dstrect.height;
            foreach (y; 0 .. dy)
            {
                ubyte* srcrow = img.scanLine(ymap[y]);
                ubyte* dstrow = scanLine(dstrect.top + y) + dstrect.left;
                foreach (x; 0 .. dx)
                {
                    ubyte srcpixel = srcrow[xmap[x]];
                    ubyte dstpixel = dstrow[x];
                    dstrow[x] = srcpixel;
                }
            }
        }
    }

    /// Detect position of black pixels in row for 9-patch markup
    private bool detectHLine(int y, ref int x0, ref int x1)
    {
        ubyte* line = scanLine(y);
        bool foundUsed = false;
        x0 = 0;
        x1 = 0;
        foreach (int x; 1 .. _w - 1)
        {
            if (line[x] < 5)
            { // opaque black pixel
                if (!foundUsed)
                {
                    x0 = x;
                    foundUsed = true;
                }
                x1 = x + 1;
            }
        }
        return x1 > x0;
    }

    /// Detect position of black pixels in column for 9-patch markup
    private bool detectVLine(int x, ref int y0, ref int y1)
    {
        bool foundUsed = false;
        y0 = 0;
        y1 = 0;
        foreach (int y; 1 .. _h - 1)
        {
            ubyte* line = scanLine(y);
            if (line[x] < 5)
            { // opaque black pixel
                if (!foundUsed)
                {
                    y0 = y;
                    foundUsed = true;
                }
                y1 = y + 1;
            }
        }
        return y1 > y0;
    }
    /// Detect nine patch using image 1-pixel border (see Android documentation)
    override bool detectNinePatch()
    {
        if (_w < 3 || _h < 3)
            return false; // image is too small
        int x00, x01, x10, x11, y00, y01, y10, y11;
        bool found = true;
        found = found && detectHLine(0, x00, x01);
        found = found && detectHLine(_h - 1, x10, x11);
        found = found && detectVLine(0, y00, y01);
        found = found && detectVLine(_w - 1, y10, y11);
        if (!found)
            return false; // no black pixels on 1-pixel frame
        NinePatch* p = new NinePatch;
        p.frame.left = x00 - 1;
        p.frame.right = _h - y01 - 1;
        p.frame.top = y00 - 1;
        p.frame.bottom = _h - y01 - 1;
        p.padding.left = x10 - 1;
        p.padding.right = _h - y11 - 1;
        p.padding.top = y10 - 1;
        p.padding.bottom = _h - y11 - 1;
        _ninePatch = p;
        return true;
    }

    override void drawGlyph(int x, int y, GlyphRef glyph, Color color)
    {
        const ubyte c = color.toGray;
        immutable(ubyte[]) src = glyph.glyph;
        const int srcdx = glyph.blackBoxX;
        const int srcdy = glyph.blackBoxY;
        const bool clipping = true; //!_clipRect.empty();
        foreach (int yy; 0 .. srcdy)
        {
            int liney = y + yy;
            if (clipping && (liney < _clipRect.top || liney >= _clipRect.bottom))
                continue;
            if (liney < 0 || liney >= _h)
                continue;
            ubyte* row = scanLine(liney);
            immutable(ubyte*) srcrow = src.ptr + yy * srcdx;
            foreach (int xx; 0 .. srcdx)
            {
                int colx = xx + x;
                if (clipping && (colx < _clipRect.left || colx >= _clipRect.right))
                    continue;
                if (colx < 0 || colx >= _w)
                    continue;

                const uint alpha = blendAlpha(color.a, srcrow[xx]);
                if (alpha == 255)
                {
                    row[colx] = c;
                }
                else if (alpha > 0)
                {
                    // apply blending
                    row[colx] = blendGray(row[colx], c, alpha);
                }
            }
        }
    }

    override void fillRect(Rect rc, Color color)
    {
        applyAlpha(color);
        if (!color.isFullyTransparent && applyClipping(rc))
        {
            const ubyte c = color.toGray;
            const ubyte a = color.a;
            const bool opaque = color.isOpaque;
            foreach (y; rc.top .. rc.bottom)
            {
                ubyte* row = scanLine(y);
                foreach (x; rc.left .. rc.right)
                {
                    if (opaque)
                    {
                        row[x] = c;
                    }
                    else
                    {
                        // apply blending
                        row[x] = blendGray(row[x], c, a);
                    }
                }
            }
        }
    }

    override void fillGradientRect(Rect rc, Color color1, Color color2, Color color3, Color color4)
    {
        if (applyClipping(rc))
        {
            ubyte c1 = color1.toGray;
            ubyte c2 = color2.toGray;
            ubyte c3 = color3.toGray;
            ubyte c4 = color4.toGray;
            foreach (y; rc.top .. rc.bottom)
            {
                // interpolate vertically at the side edges
                uint ay = (255 * (y - rc.top)) / (rc.bottom - rc.top);
                ubyte cl = blendGray(c2, c1, ay);
                ubyte cr = blendGray(c4, c3, ay);

                ubyte* row = scanLine(y);
                foreach (x; rc.left .. rc.right)
                {
                    // interpolate horizontally
                    uint ax = (255 * (x - rc.left)) / (rc.right - rc.left);
                    row[x] = blendGray(cr, cl, ax);
                }
            }
        }
    }

    override void drawPixel(int x, int y, Color color)
    {
        if (!_clipRect.contains(x, y))
            return;

        applyAlpha(color);
        ubyte* row = scanLine(y);
        if (color.isOpaque)
        {
            row[x] = color.toGray;
        }
        else if (!color.isFullyTransparent)
        {
            // apply blending
            row[x] = blendGray(row[x], color.toGray, color.a);
        }
    }
}

class ColorDrawBuf : ColorDrawBufBase
{
    private Buf!uint _buf;

    /// Create ARGB8888 draw buf of specified width and height
    this(int width, int height)
    {
        resize(width, height);
    }
    /// Create copy of `ColorDrawBuf`
    this(ColorDrawBuf src)
    {
        resize(src.width, src.height);
        if (auto len = _buf.length)
            _buf.unsafe_ptr[0 .. len] = src._buf.unsafe_ptr[0 .. len];
    }
    /// Create resized copy of `ColorDrawBuf`
    this(ColorDrawBuf src, int width, int height)
    {
        resize(width, height); // fills with transparent
        drawRescaled(Rect(0, 0, width, height), src, Rect(0, 0, src.width, src.height));
    }

    void preMultiplyAlpha()
    {
        foreach (ref pixel; _buf.unsafe_slice)
        {
            Color c = Color.fromPacked(pixel);
            c.r = ((c.r * c.a) >> 8) & 0xFF;
            c.g = ((c.g * c.a) >> 8) & 0xFF;
            c.b = ((c.b * c.a) >> 8) & 0xFF;
            pixel = c.rgba;
        }
    }

    void invertAlpha()
    {
        foreach (ref pixel; _buf.unsafe_slice)
            pixel ^= 0xFF000000;
    }

    void invertByteOrder()
    {
        foreach (ref pixel; _buf.unsafe_slice)
        {
            pixel = (pixel & 0xFF00FF00) | ((pixel & 0xFF0000) >> 16) | ((pixel & 0xFF) << 16);
        }
    }

    // for passing of image to OpenGL texture
    void invertAlphaAndByteOrder()
    {
        foreach (ref pixel; _buf.unsafe_slice)
        {
            pixel = ((pixel & 0xFF00FF00) | ((pixel & 0xFF0000) >> 16) | ((pixel & 0xFF) << 16));
            pixel ^= 0xFF000000;
        }
    }

    override inout(uint*) scanLine(int y) inout
    {
        if (y >= 0 && y < _h)
            return _buf.unsafe_ptr + _w * y;
        return null;
    }

    override void resize(int width, int height)
    {
        if (_w == width && _h == height)
            return;
        _w = width;
        _h = height;
        _buf.resize(_w * _h);
        resetClipping();
    }

    override void fill(Color color)
    {
        if (hasClipping)
            fillRect(Rect(0, 0, _w, _h), color);
        else
            _buf.unsafe_slice[] = color.rgba;
    }

    /// Apply Gaussian blur to the image
    void blur(uint blurSize)
    {
        if (blurSize == 0)
            return; // trivial case

        // utility functions to get and set color
        float[4] get(const uint[] buf, uint x, uint y)
        {
            uint c = buf[x + y * _w];
            float a = 255 - (c >> 24);
            float r = (c >> 16) & 0xFF;
            float g = (c >> 8) & 0xFF;
            float b = (c >> 0) & 0xFF;
            return [r, g, b, a];
        }

        void set(uint[] buf, uint x, uint y, float[4] c)
        {
            buf[x + y * _w] = makeRGBA(c[0], c[1], c[2], 255 - c[3]);
        }

        import std.math : exp, sqrt, PI;
        import beamui.core.math : max, min;

        // Gaussian function
        static float weight(in float x, in float sigma)
        {
            enum inv_sqrt_2pi = 1 / sqrt(2 * PI);
            return exp(-x ^^ 2 / (2 * sigma ^^ 2)) * inv_sqrt_2pi / sigma;
        }

        void blurOneDimension(const uint[] bufIn, uint[] bufOut, uint blurSize, bool horizontally)
        {
            float sigma = blurSize > 2 ? blurSize / 3.0 : blurSize / 2.0;

            foreach (x; 0 .. _w)
            {
                foreach (y; 0 .. _h)
                {
                    float[4] c;
                    c[] = 0;

                    float sum = 0;
                    foreach (int i; 1 .. blurSize + 1)
                    {
                        float[4] c1 = get(bufIn, horizontally ? min(x + i, _w - 1) : x,
                                horizontally ? y : min(y + i, _h - 1));
                        float[4] c2 = get(bufIn, horizontally ? max(x - i, 0) : x, horizontally ? y : max(y - i, 0));
                        float w = weight(i, sigma);
                        c[] += (c1[] + c2[]) * w;
                        sum += 2 * w;
                    }
                    c[] += get(bufIn, x, y)[] * (1 - sum);
                    set(bufOut, x, y, c);
                }
            }
        }
        // intermediate buffer for image
        Buf!uint tmpbuf;
        tmpbuf.resize(_buf.length);
        // do horizontal blur
        blurOneDimension(_buf[], tmpbuf.unsafe_slice, blurSize, true);
        // then do vertical blur
        blurOneDimension(tmpbuf[], _buf.unsafe_slice, blurSize, false);
    }
}
