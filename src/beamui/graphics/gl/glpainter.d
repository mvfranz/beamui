/**
OpenGL (ES) 3 painter implementation.

Copyright: dayllenger 2019-2020
License:   Boost License 1.0
Authors:   dayllenger
*/
module beamui.graphics.gl.glpainter;

import beamui.core.config;

// dfmt off
static if (USE_OPENGL):
// dfmt on
import std.algorithm.mutation : reverse;
import std.typecons : scoped;

import beamui.core.collections : Buf;
import beamui.core.geometry : BoxI, Rect, RectI, SizeI;
import beamui.core.linalg : Mat2x3, Vec2;
import beamui.core.logger : Log;
import beamui.core.math;
import beamui.core.types : tup;
import beamui.graphics.bitmap : Bitmap, onBitmapDestruction;
import beamui.graphics.brush;
import beamui.graphics.colors : Color, ColorF;
import beamui.graphics.compositing : getBlendFactors;
import beamui.graphics.flattener;
import beamui.graphics.gl.objects : TexId;
import beamui.graphics.gl.renderer;
import beamui.graphics.gl.shaders;
import beamui.graphics.gl.stroke_tiling;
import beamui.graphics.gl.textures;
import beamui.graphics.painter : GlyphInstance, MIN_RECT_F, PaintEngine;
import beamui.graphics.pen;
import beamui.graphics.polygons;
import beamui.text.glyph : onGlyphDestruction;

private nothrow:

/*
Notes:
- this module doesn't call GL at all
- all matrices and boxes are local to the containing layer, if not stated otherwise
- all source and destination pixels are premultiplied, if not stated otherwise
*/

/// Contains objects shared between GL painters and their drawing layers
public final class GLSharedData
{
    private
    {
        StdShaders sh;

        ColorStopAtlas colorStopAtlas;
        TextureCache textureCache;
        GlyphCache glyphCache;
    }

    this()
    {
        colorStopAtlas.initialize();
        onBitmapDestruction ~= &textureCache.remove;
        onGlyphDestruction ~= &glyphCache.remove;
    }

    ~this()
    {
        onBitmapDestruction -= &textureCache.remove;
        onGlyphDestruction -= &glyphCache.remove;
        debug ensureNotInGC(this);
    }
}

struct Geometry
{
    Buf!Batch batches;
    Buf!Tri triangles;

    Buf!Vec2 positions;
    Buf!ushort dataIndices;
    Buf!Vec2 positions_textured;
    Buf!ushort dataIndices_textured;
    Buf!Vec2 uvs_textured; // actually in 0..texSize range

    void clear() nothrow
    {
        batches.clear();
        triangles.clear();
        positions.clear();
        dataIndices.clear();
        positions_textured.clear();
        dataIndices_textured.clear();
        uvs_textured.clear();
    }
}

struct Cover
{
    Rect rect; /// Local to batch
    RectI clip;
    uint dataIndex;
}

struct DepthTask
{
    int index;
    uint dataIndex;
}

public final class GLPaintEngine : PaintEngine
{
    private
    {
        const(State)* _st;

        Layer* layer; // points into array, so need to handle carefully
        Buf!Layer layers;
        Buf!Set sets;

        Buf!DataChunk dataStore;

        Geometry g_opaque;
        Geometry g_transp;

        Buf!Cover covers;
        Buf!DepthTask depthTasks;
        Buf!Vec2 layerOffsets;

        Buf!Vec2 bufVerts;
        Buf!uint bufContours;
        TileGrid tileGrid;
        Buf!PackedTile tilePoints;
        Buf!ushort tileDataIndices;

        ColorStopAtlas* colorStopAtlas;
        TextureCache* textureCache;
        GlyphCache* glyphCache;

        FlatteningContourIter strokeIter;
        GpaaAppender gpaa;

        Renderer renderer;
    }

    this(GLSharedData data)
    in (data)
    {
        renderer.initialize(&data.sh);
        colorStopAtlas = &data.colorStopAtlas;
        textureCache = &data.textureCache;
        glyphCache = &data.glyphCache;
        strokeIter = new FlatteningContourIter;
    }

    ~this()
    {
        debug ensureNotInGC(this);
    }

protected:

    const(State)* st() const
    {
        return _st;
    }

    void begin(const(State)* st, FrameConfig conf)
    {
        _st = st;

        layers.clear();
        sets.clear();

        dataStore.clear();

        g_opaque.clear();
        g_transp.clear();

        covers.clear();
        depthTasks.clear();

        tileGrid.prepare(conf.width, conf.height);
        tilePoints.clear();
        tileDataIndices.clear();

        Layer lr;
        lr.clip = lr.bounds = RectI(0, 0, conf.width, conf.height);
        lr.fill = ColorF(conf.background);
        layers ~= lr;
        layer = &layers.unsafe_ref(0);
        sets ~= Set.init;

        colorStopAtlas.reset();
        gpaa.prepare();
    }

    void end()
    {
        textureCache.updateMipmaps();
        prepareSets();
        prepareLayers();
        constructCoverGeometry();
        sortBatches();

        if (g_opaque.batches.length + g_transp.batches.length)
        {
            // dfmt off
            debug (painter)
            {
                Log.fd("GL: %s bt, %s dat, %s tri, %s v",
                    g_opaque.batches.length + g_transp.batches.length,
                    dataStore.length,
                    g_opaque.triangles.length + g_transp.triangles.length,
                    g_opaque.positions.length + g_opaque.positions_textured.length +
                    g_transp.positions.length + g_transp.positions_textured.length,
                );
            }
            renderer.upload(const(DataToUpload)(
                const(GeometryToUpload)(
                    g_opaque.triangles[],
                    g_opaque.positions[],
                    g_opaque.dataIndices[],
                    g_opaque.positions_textured[],
                    g_opaque.dataIndices_textured[],
                    g_opaque.uvs_textured[],
                ),
                const(GeometryToUpload)(
                    g_transp.triangles[],
                    g_transp.positions[],
                    g_transp.dataIndices[],
                    g_transp.positions_textured[],
                    g_transp.dataIndices_textured[],
                    g_transp.uvs_textured[],
                ),
                dataStore[],
                tilePoints[],
                tileDataIndices[],
            ), const(GpaaDataToUpload)(
                gpaa.indices[],
                gpaa.positions[],
                gpaa.dataIndices[],
                gpaa.layerIndices[],
                getGlobalLayerPositions(),
            ), tileGrid);
            // dfmt on
        }
    }

    void paint()
    {
        renderer.render(const(DrawLists)(layers[], sets[], g_opaque.batches[], g_transp.batches[]));
    }

    private void prepareSets()
    {
        Set[] list = sets.unsafe_slice;
        foreach (i; 1 .. list.length)
        {
            list[i - 1].b_opaque.end = list[i].b_opaque.start;
            list[i - 1].b_transp.end = list[i].b_transp.start;
            list[i - 1].dataChunks.end = list[i].dataChunks.start;
        }
        list[$ - 1].b_opaque.end = g_opaque.batches.length;
        list[$ - 1].b_transp.end = g_transp.batches.length;
        list[$ - 1].dataChunks.end = dataStore.length;
    }

    private void prepareLayers()
    in (layers.length)
    {
        if (layers.length == 1)
            return;

        // compute optimal layer boundaries on screen, starting from leafs
        foreach_reverse (ref Layer lr; layers.unsafe_slice[1 .. $])
        {
            foreach (i, ref set; sets[][lr.sets.start .. lr.sets.end])
            {
                if (set.layer == lr.index)
                {
                    foreach (ref bt; g_opaque.batches.unsafe_slice[set.b_opaque.start .. set.b_opaque.end])
                        lr.bounds.include(bt.common.clip);
                    foreach (ref bt; g_transp.batches.unsafe_slice[set.b_transp.start .. set.b_transp.end])
                        lr.bounds.include(bt.common.clip);
                }
            }
            RectI clip = lr.clip;
            clip.translate(-clip.left, -clip.top);
            if (lr.bounds.intersect(clip))
            {
                // parent layer should have at least that size
                Layer* parent = &layers.unsafe_ref(lr.parent);
                RectI r = lr.bounds;
                r.translate(lr.clip.left, lr.clip.top);
                parent.bounds.include(r);
            }
        }
        // reset for the main layer
        {
            Layer* main = &layers.unsafe_ref(0);
            main.bounds = RectI(0, 0, main.clip.width, main.clip.height);
        }
        // do other job, iterating in straight order
        foreach (ref Layer lr; layers.unsafe_slice[1 .. $])
        {
            if (lr.empty)
                continue;

            // shift batches to the layer origin
            const shift = Vec2(-lr.bounds.left, -lr.bounds.top);
            foreach (i, ref set; sets[][lr.sets.start .. lr.sets.end])
            {
                if (set.layer == lr.index)
                {
                    const Span data = set.dataChunks;
                    foreach (ref DataChunk ch; dataStore.unsafe_slice[data.start .. data.end])
                    {
                        ch.transform = Mat2x3.translation(shift) * ch.transform;
                        ch.clipRect.translate(shift.x, shift.y);
                    }
                }
            }
            // adjust final layer coordinates
            const RectI parentBounds = layers[lr.parent].bounds;
            const xshift = lr.clip.left + lr.bounds.left - parentBounds.left;
            const yshift = lr.clip.top + lr.bounds.top - parentBounds.top;
            dataStore.unsafe_ref(lr.cmd.dataIndex).transform = Mat2x3.translation(Vec2(xshift, yshift));
        }
        // at this point, all sub-layers of empty layers are empty too
        foreach (ref Set set; sets.unsafe_slice)
        {
            if (layers[set.layerToCompose].empty)
                set.layerToCompose = 0;
        }
    }

    private void constructCoverGeometry()
    {
        foreach (Geometry* g; tup(&g_opaque, &g_transp))
        {
            foreach (ref bt; g.batches.unsafe_slice)
            {
                if (bt.type == BatchType.twopass)
                {
                    const t = g.triangles.length;
                    const Span covs = bt.twopass.covers;
                    foreach (ref cov; covers[][covs.start .. covs.end])
                    {
                        // dfmt off
                        const Vec2[4] vs = [
                            Vec2(cov.rect.left, cov.rect.top),
                            Vec2(cov.rect.left, cov.rect.bottom),
                            Vec2(cov.rect.right, cov.rect.top),
                            Vec2(cov.rect.right, cov.rect.bottom),
                        ];
                        // dfmt on
                        const v = g.positions.length;
                        g.positions ~= vs[];
                        addStrip(g.triangles, v, 4);
                        g.dataIndices.resize(g.dataIndices.length + 4, cast(ushort)cov.dataIndex);
                    }
                    bt.twopass.coverTriangles = Span(t, g.triangles.length);
                }
            }
        }
        foreach (ref set; sets[])
        {
            if (set.layerToCompose > 0)
            {
                auto g = pickGeometry(false);
                Layer* lr = &layers.unsafe_ref(set.layerToCompose);

                const SizeI sz = lr.bounds.size;
                const Vec2[4] vs = [Vec2(0, 0), Vec2(0, sz.h), Vec2(sz.w, 0), Vec2(sz.w, sz.h)];
                const v = g.positions.length;
                const t = g.triangles.length;
                g.positions ~= vs[];
                addStrip(g.triangles, v, 4);
                g.dataIndices.resize(g.dataIndices.length + 4, lr.cmd.dataIndex);
                lr.cmd.triangles = Span(t, g.triangles.length);
            }
        }
    }

    private void sortBatches()
    {
        // sort geometry front-to-back inside an opaque batch
        foreach (ref bt; g_opaque.batches[])
        {
            const Span tris = bt.common.triangles;
            reverse(g_opaque.triangles.unsafe_slice[tris.start .. tris.end]);
        }
    }

    private const(Vec2[]) getGlobalLayerPositions()
    {
        if (layers.length == 1)
            return null;

        layerOffsets.resize(layers.length);
        Vec2[] list = layerOffsets.unsafe_slice;

        foreach (i; 1 .. layers.length)
        {
            const Layer* lr = &layers[i];
            list[i] = list[lr.parent] + Vec2(lr.clip.left, lr.clip.top);
        }
        foreach (i; 1 .. layers.length)
        {
            const Layer* lr = &layers[i];
            list[i].x += lr.bounds.left;
            list[i].y += lr.bounds.top;
        }
        return list;
    }

    void beginLayer(BoxI clip, bool expand, LayerOp op)
    {
        Layer lr;
        lr.index = layers.length;
        lr.parent = layer.index;
        lr.sets.start = sets.length;
        lr.clip = RectI(clip);
        if (expand)
            lr.bounds = RectI(0, 0, clip.w, clip.h);
        lr.depth = layer.depth;
        lr.cmd.opacity = op.opacity;
        lr.cmd.composition = getBlendFactors(op.composition);
        lr.cmd.blending = op.blending;
        layers ~= lr;
        layer = &layers.unsafe_ref(lr.index);
        sets ~= makeSet(lr.index);

        gpaa.setLayerIndex(lr.index);
    }

    void composeLayer()
    {
        layer.sets.end = sets.length;
        layer.cmd.dataIndex = cast(ushort)dataStore.length;
        // setup the parent layer back
        sets ~= makeSet(layer.parent, layer.index);
        layer = &layers.unsafe_ref(layer.parent);
        // create an empty data chunk with the parent layer current depth
        const Mat2x3 mat;
        dataStore ~= prepareDataChunk(&mat);
        advanceDepth();

        gpaa.setLayerIndex(layer.index);
    }

    void clipOut(uint index, ref Contours contours, FillRule rule, bool complement)
    {
        alias S = Stenciling;
        const set = makeSet(layer.index);
        const task = DepthTask(index, dataStore.length);
        const nonzero = rule == FillRule.nonzero;
        const stenciling = nonzero ? (complement ? S.zero : S.nonzero) : (complement ? S.even : S.odd);
        if (fillPathImpl(contours, null, stenciling))
        {
            sets ~= set;
            sets ~= makeSet(layer.index);
            depthTasks ~= task;
        }
    }

    private Set makeSet(uint layer, uint layerToCompose = 0) const
    {
        return Set(Span(g_opaque.batches.length), Span(g_transp.batches.length), Span(dataStore.length), layer, layerToCompose);
    }

    void restore(uint index)
    {
        const int i = index;
        foreach (ref DepthTask task; depthTasks.unsafe_slice)
        {
            if (task.index >= i)
            {
                task.index = -1; // done
                setDepth(task.dataIndex);
            }
        }
    }

    private void setDepth(uint dataIndex)
    {
        dataStore.unsafe_ref(dataIndex).depth = layer.depth;
    }

    void paintOut(ref const Brush br)
    {
        const r = layer.clip;
        // dfmt off
        const Vec2[4] vs = [
            Vec2(r.left, r.top),
            Vec2(r.left, r.bottom),
            Vec2(r.right, r.top),
            Vec2(r.right, r.bottom),
        ];
        // dfmt on
        auto g = pickGeometry(br.isOpaque);
        const v = g.positions.length;
        const t = g.triangles.length;
        g.positions ~= vs[];
        addStrip(g.triangles, v, 4);

        if (simple(t, r, &br))
        {
            dataStore.unsafe_ref(-1).transform = Mat2x3.identity;
        }
    }

    void fillPath(ref Contours contours, ref const Brush br, FillRule rule)
    {
        fillPathImpl(contours, &br, rule == FillRule.nonzero ? Stenciling.nonzero : Stenciling.odd);
    }

    void strokePath(ref Contours contours, ref const Brush br, ref const Pen pen, bool)
    {
        bool evenlyScaled = true;
        float width = pen.width;
        if (pen.shouldScale)
        {
            const o = st.mat * Vec2(0);
            const v = st.mat * Vec2(1, 0) - o;
            const w = st.mat * Vec2(0, 1) - o;
            evenlyScaled = fequal2(v.magnitudeSquared, w.magnitudeSquared);
            width = v.length * pen.width;
        }
        if (br.type == BrushType.solid && evenlyScaled && width < 3)
            strokePathTiled(contours, br, pen, width);
        else
            strokePathAsFill(contours, br, pen);
    }

    private void strokePathTiled(ref Contours contours, ref const Brush br, ref const Pen pen, float realWidth)
    {
        bufVerts.clear();
        bufContours.clear();

        const pixelSize = 1.0f / TILE_SIZE;
        Mat2x3 mat = Mat2x3.scaling(Vec2(pixelSize)) * st.mat;
        foreach (ref cr; contours.list)
        {
            const len = cr.flatten!true(bufVerts, mat, pixelSize);
            if (len != 1)
            {
                bufContours ~= len;
                continue;
            }
            // fix degeneracies
            if (pen.cap == LineCap.butt)
            {
                bufVerts.shrink(1);
                continue;
            }
            const p = bufVerts[$ - 1];
            bufVerts.shrink(1);
            bufVerts ~= p - Vec2(pixelSize * 0.25f, 0);
            bufVerts ~= p + Vec2(pixelSize * 0.25f, 0);
            bufContours ~= 2;
        }

        const start = tilePoints.length;
        tileGrid.clipStrokeToLattice(bufVerts[], bufContours[], tilePoints, contours.trBounds, realWidth);
        const count = tilePoints.length - start;

        bool reuseBatch;
        if (g_transp.batches.length > sets[$ - 1].b_transp.start)
        {
            Batch* last = &g_transp.batches.unsafe_ref(-1);
            if (last.type == BatchType.tiled)
            {
                reuseBatch = true;
                last.common.triangles.end += count;
            }
        }
        if (!reuseBatch)
        {
            Batch bt;
            bt.type = BatchType.tiled;
            bt.common.triangles = Span(start, start + count);
            g_transp.batches ~= bt;
        }

        tileDataIndices.resize(tilePoints.length, cast(ushort)dataStore.length);

        Mat2x3 quasiMat;
        quasiMat.store[0][0] = realWidth;
        quasiMat.store[1][1] = st.aa ? 0.8f : 100; // contrast
        DataChunk data = prepareDataChunk(&quasiMat, br.solid);
        ShParams params;
        convertSolid(br.solid, br.opacity, params, data);

        dataStore ~= data;
        advanceDepth();
    }

    private void strokePathAsFill(ref Contours contours, ref const Brush br, ref const Pen pen)
    {
        auto g = pickGeometry(br.isOpaque);

        auto builder_obj = scoped!TriBuilder(g.positions, g.triangles);
        TriBuilder builder = builder_obj;

        const t = g.triangles.length;
        if (st.aa)
            builder.contour = gpaa.contour;

        // if we are in non-scaling mode, transform contours on CPU, then expand
        const minDist = pen.shouldScale ? getMinDistFromMatrix(st.mat) : 0.7f;
        strokeIter.recharge(contours, st.mat, !pen.shouldScale);
        expandStrokes(strokeIter, pen, builder, minDist);

        if (st.aa)
            gpaa.finish(dataStore.length);

        if (g.triangles.length > t)
        {
            const trivial = contours.list.length == 1 && contours.list[0].points.length < 3;
            const mat = pen.shouldScale ? st.mat : Mat2x3.identity;
            if (br.isOpaque || trivial)
            {
                simple(t, contours.trBounds, &br, &mat);
            }
            else
            {
                // we must do two-pass rendering to avoid overlaps
                // on bends and self-intersections
                const bounds = pen.shouldScale ? contours.bounds : Rect.from(contours.trBounds);
                twoPass(t, Stenciling.justCover, bounds, contours.trBounds, &br, &mat);
            }
        }
    }

    void drawImage(ref const Bitmap bmp, Vec2 p, float opacity)
    {
        const int w = bmp.width;
        const int h = bmp.height;
        const rp = Rect(p.x, p.y, p.x + w, p.y + h);
        const BoxI clip = clipByRect(transformBounds(rp));
        if (clip.empty)
            return;

        const TextureView view = textureCache.getTexture(bmp);
        if (view.empty)
            return;
        assert(view.box.w == w && view.box.h == h);

        auto g = pickGeometry(false); // fequal6(opacity, 1) // TODO: image opacity
        // dfmt off
        const Vec2[4] vs = [
            Vec2(rp.left, rp.top),
            Vec2(rp.left, rp.bottom),
            Vec2(rp.right, rp.top),
            Vec2(rp.right, rp.bottom),
        ];
        // dfmt on
        Vec2[4] uvs = [Vec2(0, 0), Vec2(0, h), Vec2(w, 0), Vec2(w, h)];
        foreach (ref uv; uvs)
        {
            uv.x += view.box.x;
            uv.y += view.box.y;
        }
        const v = g.positions_textured.length;
        const t = g.triangles.length;
        g.positions_textured ~= vs[];
        g.uvs_textured ~= uvs[];
        addStrip(g.triangles, v, 4);

        if (st.aa)
        {
            // dfmt off
            const Vec2[4] silhouette = [
                Vec2(rp.left, rp.top),
                Vec2(rp.left, rp.bottom),
                Vec2(rp.right, rp.bottom),
                Vec2(rp.right, rp.top),
            ];
            // dfmt on
            gpaa.add(silhouette[]);
            gpaa.finish(dataStore.length);
        }

        ShParams params;
        params.kind = PaintKind.image;
        params.image = ParamsImage(view.tex, view.texSize, opacity);

        Batch bt;
        bt.type = BatchType.simple;
        bt.common.clip = RectI(clip);
        bt.common.params = params;
        bt.common.triangles = Span(t, g.triangles.length);
        bt.simple.hasUV = true;
        g.batches ~= bt;

        g.dataIndices_textured.resize(g.positions_textured.length, cast(ushort)dataStore.length);
        dataStore ~= prepareDataChunk();

        advanceDepth();
    }

    void drawNinePatch(ref const Bitmap bmp, ref const NinePatchInfo info, float opacity)
    {
        const rp = Rect(info.dst_x0, info.dst_y0, info.dst_x3, info.dst_y3);
        const BoxI clip = clipByRect(transformBounds(rp));
        if (clip.empty)
            return;

        const TextureView view = textureCache.getTexture(bmp);
        if (view.empty)
            return;
        assert(view.box.w == bmp.width && view.box.h == bmp.height);

        auto g = pickGeometry(false);
        // dfmt off
        const Vec2[16] vs = [
            Vec2(info.dst_x0, info.dst_y0),
            Vec2(info.dst_x0, info.dst_y1),
            Vec2(info.dst_x1, info.dst_y0),
            Vec2(info.dst_x1, info.dst_y1),
            Vec2(info.dst_x2, info.dst_y0),
            Vec2(info.dst_x2, info.dst_y1),
            Vec2(info.dst_x3, info.dst_y0),
            Vec2(info.dst_x3, info.dst_y1),
            Vec2(info.dst_x0, info.dst_y2),
            Vec2(info.dst_x0, info.dst_y3),
            Vec2(info.dst_x1, info.dst_y2),
            Vec2(info.dst_x1, info.dst_y3),
            Vec2(info.dst_x2, info.dst_y2),
            Vec2(info.dst_x2, info.dst_y3),
            Vec2(info.dst_x3, info.dst_y2),
            Vec2(info.dst_x3, info.dst_y3),
        ];
        Vec2[16] uvs = [
            Vec2(info.x0, info.y0),
            Vec2(info.x0, info.y1),
            Vec2(info.x1, info.y0),
            Vec2(info.x1, info.y1),
            Vec2(info.x2, info.y0),
            Vec2(info.x2, info.y1),
            Vec2(info.x3, info.y0),
            Vec2(info.x3, info.y1),
            Vec2(info.x0, info.y2),
            Vec2(info.x0, info.y3),
            Vec2(info.x1, info.y2),
            Vec2(info.x1, info.y3),
            Vec2(info.x2, info.y2),
            Vec2(info.x2, info.y3),
            Vec2(info.x3, info.y2),
            Vec2(info.x3, info.y3),
        ];
        // dfmt on
        foreach (ref uv; uvs)
        {
            uv.x += view.box.x;
            uv.y += view.box.y;
        }
        const v = g.positions_textured.length;
        g.positions_textured ~= vs[];
        g.uvs_textured ~= uvs[];

        // dfmt off
        Tri[18] tris = [
            Tri(0, 1, 2), Tri(1, 2, 3),
            Tri(2, 3, 4), Tri(3, 4, 5),
            Tri(4, 5, 6), Tri(5, 6, 7),
            Tri(1, 8, 3), Tri(8, 3, 10),
            Tri(3, 10, 5), Tri(10, 5, 12),
            Tri(5, 12, 7), Tri(12, 7, 14),
            Tri(8, 9, 10), Tri(9, 10, 11),
            Tri(10, 11, 12), Tri(11, 12, 13),
            Tri(12, 13, 14), Tri(13, 14, 15),
        ];
        // dfmt on
        foreach (ref tri; tris)
        {
            tri.v0 += v;
            tri.v1 += v;
            tri.v2 += v;
        }
        const t = g.triangles.length;
        g.triangles ~= tris[];

        if (st.aa)
        {
            // dfmt off
            const Vec2[4] silhouette = [
                Vec2(rp.left, rp.top),
                Vec2(rp.left, rp.bottom),
                Vec2(rp.right, rp.bottom),
                Vec2(rp.right, rp.top),
            ];
            // dfmt on
            gpaa.add(silhouette[]);
            gpaa.finish(dataStore.length);
        }

        ShParams params;
        params.kind = PaintKind.image;
        params.image = ParamsImage(view.tex, view.texSize, opacity);

        Batch bt;
        bt.type = BatchType.simple;
        bt.common.clip = RectI(clip);
        bt.common.params = params;
        bt.common.triangles = Span(t, g.triangles.length);
        bt.simple.hasUV = true;
        g.batches ~= bt;

        g.dataIndices_textured.resize(g.positions_textured.length, cast(ushort)dataStore.length);
        dataStore ~= prepareDataChunk();

        advanceDepth();
    }

    void drawText(const GlyphInstance[] run, Color c)
    {
        const clip = RectI(clipByRect(transformBounds(computeTextRunBounds(run))));
        if (clip.empty)
            return;

        auto g = pickGeometry(false);

        Batch bt;
        bt.type = BatchType.simple;
        bt.common.clip = clip;
        bt.common.params.kind = PaintKind.text;
        bt.common.triangles = Span(g.triangles.length, g.triangles.length);
        bt.simple.hasUV = true;

        Batch* similar;
        ParamsText params;
        bool firstGlyph = true;
        foreach (gi; run)
        {
            const TextureView view = glyphCache.getTexture(gi.glyph);
            if (view.empty)
                continue;

            if (firstGlyph)
            {
                firstGlyph = false;
                params = ParamsText(view.tex, view.texSize);
                similar = hasSimilarTextBatch(view.tex);
            }
            else if (params.tex !is view.tex)
            {
                if (similar)
                {
                    similar.common.clip.include(clip);
                    similar.common.triangles.end = g.triangles.length;
                    similar = null;
                }
                else
                {
                    bt.common.params.text = params;
                    bt.common.triangles.end = g.triangles.length;
                    g.batches ~= bt;
                }
                bt.common.triangles.start = g.triangles.length;
                params = ParamsText(view.tex, view.texSize);
            }
            addGlyph(*g, gi, view);
        }
        if (!params.tex)
            return;

        assert(bt.common.triangles.start < g.triangles.length);
        if (similar)
        {
            similar.common.clip.include(clip);
            similar.common.triangles.end = g.triangles.length;
        }
        else
        {
            bt.common.params.text = params;
            bt.common.triangles.end = g.triangles.length;
            g.batches ~= bt;
        }
        g.dataIndices_textured.resize(g.positions_textured.length, cast(ushort)dataStore.length);
        dataStore ~= prepareDataChunk(null, c);
        advanceDepth();
    }

private:

    static Rect computeTextRunBounds(const GlyphInstance[] run)
    {
        Rect r = MIN_RECT_F;
        foreach (ref gi; run)
        {
            r.left = min(r.left, gi.position.x);
            r.top = min(r.top, gi.position.y);
            r.right = max(r.right, gi.position.x + gi.glyph.correctedBlackBoxX);
            r.bottom = max(r.bottom, gi.position.y + gi.glyph.blackBoxY);
        }
        return r;
    }

    void addGlyph(ref Geometry g, GlyphInstance gi, ref const TextureView view)
    {
        const float x = gi.position.x;
        const float y = gi.position.y;
        const float w = view.box.w;
        const float h = view.box.h;
        const Vec2[4] vs = [Vec2(x, y), Vec2(x, y + h), Vec2(x + w, y), Vec2(x + w, y + h)];
        Vec2[4] uvs = [Vec2(0, 0), Vec2(0, h), Vec2(w, 0), Vec2(w, h)];
        foreach (ref uv; uvs)
        {
            uv.x += view.box.x;
            uv.y += view.box.y;
        }
        const v = g.positions_textured.length;
        g.positions_textured ~= vs[];
        g.uvs_textured ~= uvs[];
        addStrip(g.triangles, v, 4);
    }

    bool fillPathImpl(ref Contours contours, const Brush* br, Stenciling stenciling)
    {
        auto g = pickGeometry(br ? br.isOpaque : true);

        const lst = contours.list;
        if (lst.length == 1)
        {
            if (lst[0].points.length < 3)
                return false;

            const RectI clip = lst[0].trBounds;
            const v = g.positions.length;
            const t = g.triangles.length;
            uint pcount = lst[0].flatten!false(g.positions, st.mat);
            // remove the extra point
            if (lst[0].closed)
            {
                g.positions.shrink(1);
                pcount--;
            }
            addFan(g.triangles, v, pcount);

            if (st.aa)
            {
                gpaa.add(g.positions[][v .. $]);
                gpaa.finish(dataStore.length);
            }
            // spline is convex iff hull of its control points is convex
            if (isConvex(lst[0].points) && stenciling != Stenciling.zero && stenciling != Stenciling.even)
            {
                return simple(t, clip, br);
            }
            else
            {
                return twoPass(t, stenciling, lst[0].bounds, clip, br);
            }
        }
        else
        {
            // C(S(p)) = C(S(p_0 + p_1 + ... + p_n)),
            // where S - stencil, C - cover

            const t = g.triangles.length;
            foreach (ref cr; lst)
            {
                if (cr.points.length < 3)
                    continue;

                const v = g.positions.length;
                uint pcount = cr.flatten!false(g.positions, st.mat);
                if (cr.closed)
                {
                    g.positions.shrink(1);
                    pcount--;
                }
                addFan(g.triangles, v, pcount);
                if (st.aa)
                    gpaa.add(g.positions[][v .. $]);
            }
            if (st.aa)
                gpaa.finish(dataStore.length);

            if (g.triangles.length > t)
                return twoPass(t, stenciling, contours.bounds, contours.trBounds, br);
            else
                return false;
        }
    }

    // TODO: find more opportunities for merging

    Geometry* pickGeometry(bool opaque)
    {
        return opaque ? &g_opaque : &g_transp;
    }

    bool simple(uint tstart, RectI clip, const Brush* br, const Mat2x3* m = null)
    {
        DataChunk data = prepareDataChunk(m);
        ShParams params;
        if (!convertBrush(br, params, data))
            return false;

        const opaque = br ? br.isOpaque : true;
        auto g = pickGeometry(opaque);
        // try to merge
        if (auto last = hasSimilarSimpleBatch(params.kind, opaque))
        {
            last.common.clip.include(clip);
            assert(last.common.triangles.end == tstart);
            last.common.triangles.end = g.triangles.length;
        }
        else
        {
            Batch bt;
            bt.type = BatchType.simple;
            bt.common.clip = clip;
            bt.common.params = params;
            bt.common.triangles = Span(tstart, g.triangles.length);
            g.batches ~= bt;
        }
        doneBatch(*g, data);
        return true;
    }

    /// Stencil, than cover
    bool twoPass(uint tstart, Stenciling stenciling, Rect bbox, RectI clip, const Brush* br, const Mat2x3* m = null)
    {
        DataChunk data = prepareDataChunk(m);
        ShParams params;
        if (!convertBrush(br, params, data))
            return false;

        if (stenciling == Stenciling.zero || stenciling == Stenciling.even)
        {
            import std.math : SQRT2;

            bbox.expand(bbox.width * SQRT2, bbox.height * SQRT2);
        }

        const opaque = br ? br.isOpaque : true;
        auto g = pickGeometry(opaque);
        const coverIdx = covers.length;
        covers ~= Cover(bbox, clip, dataStore.length);
        // try to merge
        if (auto last = hasSimilarTwoPassBatch(params.kind, opaque, stenciling, clip))
        {
            last.common.clip.include(clip);
            assert(last.common.triangles.end == tstart);
            last.common.triangles.end = g.triangles.length;
            last.twopass.covers.end++;
        }
        else
        {
            Batch bt;
            bt.type = BatchType.twopass;
            bt.common.clip = clip;
            bt.common.params = params;
            bt.common.triangles = Span(tstart, g.triangles.length);
            bt.twopass.covers = Span(coverIdx, coverIdx + 1);
            bt.twopass.stenciling = stenciling;
            g.batches ~= bt;
        }
        doneBatch(*g, data);
        return true;
    }

    Batch* hasSimilarSimpleBatch(PaintKind kind, bool opaque)
    in (sets.length)
    {
        Batch* last;
        if (kind == PaintKind.empty || kind == PaintKind.solid)
        {
            if (opaque)
            {
                if (g_opaque.batches.length > sets[$ - 1].b_opaque.start)
                    last = &g_opaque.batches.unsafe_ref(-1);
            }
            else
            {
                if (g_transp.batches.length > sets[$ - 1].b_transp.start)
                    last = &g_transp.batches.unsafe_ref(-1);
            }
        }
        if (last && last.type == BatchType.simple && last.common.params.kind == kind)
            return last;
        return null;
    }

    Batch* hasSimilarTextBatch(const TexId* tex)
    in (sets.length)
    {
        if (tex && g_transp.batches.length > sets[$ - 1].b_transp.start)
        {
            Batch* last = &g_transp.batches.unsafe_ref(-1);
            if (last.type == BatchType.simple)
            {
                const params = &last.common.params;
                if (params.kind == PaintKind.text && params.text.tex is tex)
                    return last;
            }
        }
        return null;
    }

    Batch* hasSimilarTwoPassBatch(PaintKind kind, bool opaque, Stenciling stenciling, RectI clip)
    in (sets.length)
    {
        Batch* last;
        if (kind == PaintKind.empty || kind == PaintKind.solid)
        {
            if (opaque)
            {
                if (g_opaque.batches.length > sets[$ - 1].b_opaque.start)
                    last = &g_opaque.batches.unsafe_ref(-1);
            }
            else
            {
                if (g_transp.batches.length > sets[$ - 1].b_transp.start)
                    last = &g_transp.batches.unsafe_ref(-1);
            }
        }
        if (last && last.type == BatchType.twopass && last.common.params.kind == kind)
        {
            const bt = last.twopass;
            if (bt.stenciling == stenciling)
            {
                // we can merge non-overlapping covers
                foreach (ref cov; covers[][bt.covers.start .. bt.covers.end])
                {
                    if (clip.intersects(cov.clip))
                        return null;
                }
                return last;
            }
        }
        return null;
    }

    void doneBatch(ref Geometry g, ref DataChunk data)
    {
        g.dataIndices.resize(g.positions.length, cast(ushort)dataStore.length);
        dataStore ~= data;
        advanceDepth();
    }

    void advanceDepth()
    {
        layer.depth *= 0.999f;
    }

    DataChunk prepareDataChunk(const Mat2x3* m = null, Color c = Color.transparent)
    {
        // dfmt off
        return DataChunk(
            m ? *m : st.mat,
            layer.depth,
            0,
            Rect.from(st.clipRect),
            ColorF(c).premultiplied,
        );
        // dfmt on
    }

    bool convertBrush(const Brush* br, ref ShParams params, ref DataChunk data)
    {
        if (dataStore.length >= MAX_DATA_CHUNKS)
            return false;
        if (!br)
            return true; // PaintKind.empty

        final switch (br.type) with (BrushType)
        {
        case solid:
            return convertSolid(br.solid, br.opacity, params, data);
        case linear:
            return convertLinear(br.linear, br.opacity, params, data);
        case radial:
            return convertRadial(br.radial, br.opacity, params, data);
        case pattern:
            return convertPattern(br.pattern, br.opacity, params, data);
        }
    }

    bool convertSolid(Color cu, float opacity, ref ShParams params, ref DataChunk data)
    {
        ColorF c = cu;
        c.a *= opacity;
        data.color = c.premultiplied;
        params.kind = PaintKind.solid;
        return true;
    }

    bool convertLinear(ref const LinearGradient grad, float opacity, ref ShParams params, ref DataChunk data)
    in (grad.colors.length >= 2)
    {
        const start = data.transform * grad.start;
        const end = data.transform * grad.end;
        if (fequal2(start.x, end.x) && fequal2(start.y, end.y))
            return convertSolid(grad.colors[$ - 1], opacity, params, data);

        const count = grad.colors.length;
        const row = ColorStopAtlasRow(grad.colors, opacity);
        const atlasIndex = colorStopAtlas.add(row);
        // dfmt off
        params.kind = PaintKind.linear;
        params.linear = ParamsLG(
            start,
            end,
            grad.stops[0 .. count],
            colorStopAtlas.tex,
            atlasIndex,
        );
        // dfmt on
        return true;
    }

    bool convertRadial(ref const RadialGradient grad, float opacity, ref ShParams params, ref DataChunk data)
    in (grad.colors.length >= 2)
    {
        const radius = (data.transform * Vec2(grad.radius, 0) - data.transform * Vec2(0)).length;
        if (fzero2(radius))
            return convertSolid(grad.colors[$ - 1], opacity, params, data);

        const center = data.transform * grad.center;

        const count = grad.colors.length;
        const row = ColorStopAtlasRow(grad.colors, opacity);
        const atlasIndex = colorStopAtlas.add(row);
        // dfmt off
        params.kind = PaintKind.radial;
        params.radial = ParamsRG(
            center,
            radius,
            grad.stops[0 .. count],
            colorStopAtlas.tex,
            atlasIndex,
        );
        // dfmt on
        return true;
    }

    bool convertPattern(ref const ImagePattern pat, float opacity, ref ShParams params, ref DataChunk data)
    in (pat.image)
    {
        const TextureView view = textureCache.getTexture(*pat.image);
        if (view.empty)
            return false; // skip rendering

        // dfmt off
        params.kind = PaintKind.pattern;
        params.pattern = ParamsPattern(
            view.tex,
            view.texSize,
            view.box,
            (data.transform * pat.transform).inverted,
            opacity,
        );
        // dfmt on
        return true;
    }
}

void addFan(ref Buf!Tri output, uint vstart, size_t vcount)
in (vcount >= 2)
{
    const v0 = vstart;
    const tris = cast(uint)vcount - 2;
    output.reserve(output.length + tris);
    foreach (v; v0 .. v0 + tris)
        output ~= Tri(v0, v + 1, v + 2);
}

void addStrip(ref Buf!Tri output, uint vstart, size_t vcount)
in (vcount >= 2)
{
    const v0 = vstart;
    const tris = cast(uint)vcount - 2;
    output.reserve(output.length + tris);
    foreach (v; v0 .. v0 + tris)
        output ~= Tri(v, v + 1, v + 2);
}

struct LineAppender
{
nothrow:
    @property bool isReady() const
    {
        return positions !is null;
    }

    private Buf!Vec2* positions;
    private Buf!uint* indices;
    private uint istart;

    this(ref Buf!Vec2 positions, ref Buf!uint indices)
    in (positions.length > 0)
    {
        this.positions = &positions;
        this.indices = &indices;
    }

    void begin()
    in (positions)
    {
        istart = positions.length;
    }

    void end()
    in (positions)
    {
        const iend = positions.length;
        if (iend == istart)
            return;

        foreach (i; istart .. iend - 1)
        {
            indices.put(i - 1);
            indices.put(i);
        }
        istart = iend;
    }

    void v(Vec2 v0)
    in (positions)
    {
        positions.put(v0);
    }

    void vs(const Vec2[] points)
    in (positions)
    {
        positions.put(points);
    }
}

final class TriBuilder : StrokeBuilder
{
nothrow:
    private
    {
        Buf!Vec2* positions;
        Buf!Tri* triangles;
        LineAppender contour;

        enum Mode
        {
            strip,
            fan
        }

        Mode mode;
        uint vstart;
    }

    this(ref Buf!Vec2 positions, ref Buf!Tri triangles)
    {
        this.positions = &positions;
        this.triangles = &triangles;
    }

    void beginContour()
    {
        vstart = positions.length;
    }

    void add(Vec2 left, Vec2 right)
    {
        positions.put(left);
        positions.put(right);
    }

    Buf!Vec2* beginFanLeft(Vec2 center)
    {
        endContour();
        mode = Mode.fan;
        positions.put(center);
        return positions;
    }

    Buf!Vec2* beginFanRight(Vec2 center)
    {
        endContour();
        mode = Mode.fan;
        positions.put(center);
        return positions;
    }

    void endFan()
    {
        endContour();
    }

    void breakStrip()
    {
        endContour();
    }

    void endContour()
    {
        const vend = positions.length;
        if (vend - vstart < 3)
        {
            vstart = vend;
            mode = Mode.strip;
            return;
        }
        // generate indices
        const tris = vend - vstart - 2;
        foreach (v; vstart .. vstart + tris)
        {
            triangles.put(Tri(mode == Mode.strip ? v : vstart, v + 1, v + 2));
        }
        // generate line silhouette for further antialiasing
        if (contour.isReady)
        {
            contour.begin();
            if (mode == Mode.strip)
            {
                contour.v((*positions)[vstart]);
                for (uint v = vstart + 1; v < vend; v += 2)
                    contour.v((*positions)[v]);
                contour.v((*positions)[vend - 2]);
                contour.end();
                for (uint v = vstart; v < vend; v += 2)
                    contour.v((*positions)[v]);
            }
            else
            {
                contour.vs((*positions)[][vstart .. vend]);
            }
            contour.end();
        }

        vstart = vend;
        mode = Mode.strip;
    }
}

struct GpaaAppender
{
nothrow:
    @property LineAppender contour()
    {
        return appender;
    }

    private
    {
        Buf!uint indices;
        Buf!Vec2 positions;
        Buf!ushort dataIndices;
        Buf!ushort layerIndices;
        LineAppender appender;

        uint layerIndex;
    }

    void prepare()
    {
        indices.clear();
        dataIndices.clear();
        positions.clear();
        positions ~= Vec2(0, 0);
        appender = LineAppender(positions, indices);
    }

    void setLayerIndex(uint i)
    {
        layerIndex = i;
    }

    void add(const Vec2[] points)
    {
        appender.begin();
        appender.vs(points);
        const fst = points[0];
        const lst = points[$ - 1];
        if (!fequal2(fst.x, lst.x) || !fequal2(fst.y, lst.y))
            appender.v(fst);
        appender.end();
    }

    void finish(uint dataIndex)
    {
        dataIndices.resize(positions.length, cast(ushort)dataIndex);
        layerIndices.resize(positions.length, cast(ushort)layerIndex);
    }
}

void ensureNotInGC(const Object object)
{
    import core.memory : GC;
    import core.stdc.stdio : fprintf, stderr;
    import beamui.core.functions : getShortClassName;

    // the old way of checking this obliterates assert messages
    static if (__VERSION__ >= 2090)
    {
        if (GC.inFinalizer())
        {
            const name = getShortClassName(object);
            fprintf(stderr, "Error: %.*s must be destroyed manually.\n", cast(int)name.length, name.ptr);
        }
    }
}
