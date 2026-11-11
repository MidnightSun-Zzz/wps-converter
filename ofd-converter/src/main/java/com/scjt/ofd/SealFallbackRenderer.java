package com.scjt.ofd;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.graphics.blend.BlendMode;
import org.apache.pdfbox.pdmodel.graphics.image.LosslessFactory;
import org.apache.pdfbox.pdmodel.graphics.image.PDImageXObject;
import org.apache.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState;
import org.bouncycastle.asn1.ASN1InputStream;
import org.bouncycastle.asn1.ASN1Sequence;
import org.ofdrw.converter.canvas.CanvasImageMaker;
import org.ofdrw.converter.utils.CommonUtil;
import org.ofdrw.core.basicType.ST_Box;
import org.ofdrw.core.basicType.ST_Loc;
import org.ofdrw.core.signatures.Signature;
import org.ofdrw.core.signatures.Signatures;
import org.ofdrw.core.signatures.appearance.Seal;
import org.ofdrw.core.signatures.appearance.StampAnnot;
import org.ofdrw.core.signatures.sig.SignedInfo;
import org.ofdrw.gm.ses.parse.SESVersionHolder;
import org.ofdrw.gm.ses.parse.VersionParser;
import org.ofdrw.reader.OFDReader;
import org.ofdrw.reader.ResourceLocator;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * 补画 OFDRW PDFExporter 没有渲染出来的印章。
 *
 * <p>OFDRW 2.5.1 只处理签名值里的印章。有些 WPS/KingGrid 生成的 OFD 把印章放在
 * {@code SignedInfo/Seal}，或者签名值文件带尾部数据导致解析失败；这两种情况都会
 * 被它静默跳过。这里按 {@code StampAnnot} 的位置把印章叠到导出的 PDF 上。
 * 印章问题不能影响整篇转换，所以任何异常都只跳过补画，不向外抛。</p>
 */
final class SealFallbackRenderer {

    private SealFallbackRenderer() {
    }

    static void apply(Path ofdPath, Path pdfPath) {
        Path temporary = null;
        try (OFDReader reader = new OFDReader(ofdPath)) {
            if (!reader.hasSignature()) {
                return;
            }
            Signatures signatures = reader.getDefaultSignatures();
            if (signatures == null || signatures.getSignatures().isEmpty()) {
                return;
            }
            Map<String, Integer> pageIndexes = pageIndexes(reader);
            Set<String> alreadyRendered = renderedStampIds(reader);
            try (PDDocument document = Loader.loadPDF(pdfPath.toFile())) {
                boolean changed = false;
                for (Signature signature : signatures.getSignatures()) {
                    org.ofdrw.core.signatures.sig.Signature description =
                            readSignature(reader, signature);
                    if (description == null) {
                        System.err.println("Signature description unreadable: "
                                + signature.getBaseLoc());
                        continue;
                    }
                    SignedInfo signedInfo = description.getSignedInfo();
                    SealImage image = null;
                    Seal seal = signedInfo.getSeal();
                    if (seal != null) {
                        image = readSealImage(reader, signature, seal);
                    }
                    if (image == null && description.getSignedValue() != null) {
                        // KingGrid/WPS 会用相对路径，OFDReader 解析不了时由这里自己读。
                        image = readSignedValueImage(
                                reader, signature, description.getSignedValue());
                    }
                    if (image == null) {
                        continue;
                    }
                    PDImageXObject xobject = createXObject(document, image);
                    if (xobject == null) {
                        continue;
                    }
                    for (StampAnnot annot : signedInfo.getStampAnnots()) {
                        if (annot == null || alreadyRendered.contains(annot.getID())) {
                            continue;
                        }
                        Integer pageIndex = pageIndexes.get(annot.getPageRef().toString());
                        if (pageIndex == null || pageIndex < 0
                                || pageIndex >= document.getNumberOfPages()) {
                            continue;
                        }
                        draw(document, document.getPage(pageIndex), xobject, annot);
                        changed = true;
                    }
                }
                if (!changed) {
                    return;
                }
                temporary = Files.createTempFile(
                        pdfPath.toAbsolutePath().getParent(), "ofd-seal-", ".pdf");
                document.save(temporary.toFile());
            }
            Files.move(temporary, pdfPath, StandardCopyOption.REPLACE_EXISTING);
        } catch (Throwable error) {
            System.err.println("OFD seal fallback skipped: " + error);
            error.printStackTrace(System.err);
        } finally {
            if (temporary != null) {
                try {
                    Files.deleteIfExists(temporary);
                } catch (Exception ignored) {
                    // 清理失败不影响主流程
                }
            }
        }
    }

    private static Map<String, Integer> pageIndexes(OFDReader reader) {
        Map<String, Integer> indexes = new HashMap<>();
        for (int page = 1; page <= reader.getNumberOfPages(); page++) {
            indexes.put(reader.getPageObjectId(page).toString(), page - 1);
        }
        return indexes;
    }

    private static Set<String> renderedStampIds(OFDReader reader) {
        Set<String> ids = new HashSet<>();
        try {
            for (var entity : reader.getStampAnnots()) {
                for (StampAnnot annot : entity.getStampAnnots()) {
                    ids.add(annot.getID());
                }
            }
        } catch (RuntimeException ignored) {
            // 读不到已渲染集合时按空集处理，宁可重画也不要漏掉印章。
        }
        return ids;
    }

    private static org.ofdrw.core.signatures.sig.Signature readSignature(
            OFDReader reader, Signature signature) {
        ResourceLocator locator = reader.getResourceLocator();
        locator.save();
        try {
            locator.cd(reader.getDefaultDocSignaturesPath().parent());
            return locator.get(signature.getBaseLoc(),
                    org.ofdrw.core.signatures.sig.Signature::new);
        } catch (Exception error) {
            return null;
        } finally {
            locator.restore();
        }
    }

    private static SealImage readSealImage(OFDReader reader, Signature signature, Seal seal) {
        try {
            SESVersionHolder holder = VersionParser.parseSES_SealVersion(
                    firstSequence(readSignatureFile(reader, signature, seal.getBaseLoc())));
            String type;
            byte[] data;
            switch (holder.getVersion()) {
                case v1 -> {
                    var picture = holder.getInstanceV1Seal().getEsealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                case v4 -> {
                    var picture = holder.getInstanceV4Seal().geteSealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                case v5 -> {
                    var picture = holder.getInstanceV5Seal().geteSealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                default -> {
                    return null;
                }
            }
            return data == null ? null : new SealImage(type, data);
        } catch (Exception error) {
            return null;
        }
    }

    private static SealImage readSignedValueImage(
            OFDReader reader, Signature signature, ST_Loc signedValue) {
        try {
            SESVersionHolder holder = VersionParser.parseSES_SignatureVersion(
                    firstSequence(readSignatureFile(reader, signature, signedValue)));
            String type;
            byte[] data;
            switch (holder.getVersion()) {
                case v1 -> {
                    var picture = holder.getInstanceV1()
                            .getToSign().getEseal().getEsealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                case v4 -> {
                    var picture = holder.getInstanceV4()
                            .getToSign().getEseal().geteSealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                case v5 -> {
                    var picture = holder.getInstanceV5()
                            .getToSign().getEseal().geteSealInfo().getPicture();
                    type = picture.getType() == null ? null : picture.getType().getString();
                    data = picture.getData() == null ? null : picture.getData().getOctets();
                }
                default -> {
                    return null;
                }
            }
            return data == null ? null : new SealImage(type, data);
        } catch (Exception error) {
            System.err.println("SignedValue seal parse failed: " + error);
            error.printStackTrace(System.err);
            return null;
        }
    }

    private static byte[] readSignatureFile(
            OFDReader reader, Signature signature, ST_Loc location) throws Exception {
        ResourceLocator locator = reader.getResourceLocator();
        locator.save();
        try {
            locator.cd(reader.getDefaultDocSignaturesPath().parent());
            locator.cd(signature.getBaseLoc().parent());
            return Files.readAllBytes(locator.getFile(location));
        } finally {
            locator.restore();
        }
    }

    private static ASN1Sequence firstSequence(byte[] bytes) throws Exception {
        try (ASN1InputStream input = new ASN1InputStream(bytes)) {
            ASN1Sequence sequence = ASN1Sequence.getInstance(input.readObject());
            if (sequence == null) {
                throw new IllegalArgumentException("empty ASN.1 signature value");
            }
            return sequence;
        }
    }

    private static PDImageXObject createXObject(PDDocument document, SealImage image) {
        byte[] bytes = image.bytes();
        if (bytes == null || bytes.length == 0) {
            return null;
        }
        if (image.type() != null && "ofd".equalsIgnoreCase(image.type().trim())) {
            try (OFDReader sealReader = new OFDReader(new ByteArrayInputStream(bytes))) {
                CanvasImageMaker maker = new CanvasImageMaker(
                        sealReader, CommonUtil.dpiToPpm(300));
                BufferedImage rendered = maker.makePage(0);
                return rendered == null ? null : LosslessFactory.createFromImage(document, rendered);
            } catch (Exception error) {
                return null;
            }
        }
        try {
            return PDImageXObject.createFromByteArray(document, bytes, "Seal");
        } catch (Exception error) {
            try (ByteArrayInputStream input = new ByteArrayInputStream(bytes)) {
                BufferedImage rendered = ImageIO.read(input);
                return rendered == null ? null : LosslessFactory.createFromImage(document, rendered);
            } catch (Exception ignored) {
                return null;
            }
        }
    }

    private static void draw(PDDocument document, PDPage page, PDImageXObject image,
                             StampAnnot annot) throws Exception {
        ST_Box boundary = annot.getBoundary();
        if (boundary == null || boundary.getWidth() == null || boundary.getHeight() == null) {
            return;
        }
        float scale = 72f / 25.4f;
        float pageHeight = page.getMediaBox().getHeight();
        float boundaryX = number(boundary.getTopLeftX());
        float boundaryY = number(boundary.getTopLeftY());
        float boundaryWidth = number(boundary.getWidth());
        float boundaryHeight = number(boundary.getHeight());
        float x = boundaryX * scale;
        float y = pageHeight - (boundaryY + boundaryHeight) * scale;
        try (PDPageContentStream stream = new PDPageContentStream(
                document, page, PDPageContentStream.AppendMode.APPEND, true, true)) {
            stream.saveGraphicsState();
            ST_Box clip = annot.getClip();
            if (clip != null && number(clip.getWidth()) > 0 && number(clip.getHeight()) > 0) {
                float clipX = (boundaryX + number(clip.getTopLeftX())) * scale;
                float clipY = pageHeight - (boundaryY + number(clip.getTopLeftY())
                        + number(clip.getHeight())) * scale;
                stream.addRect(clipX, clipY, number(clip.getWidth()) * scale,
                        number(clip.getHeight()) * scale);
                stream.clip();
            }
            PDExtendedGraphicsState state = new PDExtendedGraphicsState();
            state.setBlendMode(BlendMode.DARKEN);
            state.setNonStrokingAlphaConstant(1f);
            state.setStrokingAlphaConstant(1f);
            stream.setGraphicsStateParameters(state);
            stream.drawImage(image, x, y, boundaryWidth * scale, boundaryHeight * scale);
            stream.restoreGraphicsState();
        }
    }

    private static float number(Double value) {
        return value == null ? 0f : value.floatValue();
    }

    private record SealImage(String type, byte[] bytes) {
    }
}
