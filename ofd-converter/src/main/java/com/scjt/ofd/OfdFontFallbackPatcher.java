package com.scjt.ofd;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * 给 OFD 里没有可用字体文件的字体资源嵌入一个兜底字体。
 *
 * <p>红头和标题用的字体各家不一样，有些 OFD 既不内嵌字体，系统里也没有对应字库，
 * PDF 里就会只剩方框。正文一般能正常显示，所以只补标题、红头用到的缺失字体：
 * 字号明显大于正文，或者文字颜色是红色。正文的字体资源不动，已经有字体文件的
 * 资源也不覆盖。</p>
 */
final class OfdFontFallbackPatcher {

    private static final String DEFAULT_FALLBACK_FONT =
            "/usr/share/fonts/truetype/gongwen/FZXiaoBiaoSong-B05S.ttf";
    private static final String FALLBACK_FILE_NAME = "ofd_fallback_fzx.ttf";
    private static final String OFD_NS = "http://www.ofdspec.org/2016";
    /** 公文标题一般是 2 号字（约 7.8mm），正文 3 号字约 5.6mm。 */
    private static final double TITLE_MIN_SIZE_MM = 6.5;

    private OfdFontFallbackPatcher() {
    }

    /**
     * 返回可用的 OFD 路径。没有需要补字体的资源时直接返回原路径。
     */
    static Path patch(Path source) {
        Path fallbackFont = Path.of(System.getenv().getOrDefault(
                "OFD_FALLBACK_FONT", DEFAULT_FALLBACK_FONT));
        if (!Files.isRegularFile(fallbackFont)) {
            return source;
        }
        Path target = null;
        try {
            byte[] fontBytes = Files.readAllBytes(fallbackFont);
            target = Files.createTempFile("ofd-font-fallback-", ".ofd");
            List<EntryData> raw = new ArrayList<>();
            Set<String> names = new HashSet<>();
            try (ZipFile zip = new ZipFile(source.toFile())) {
                var iter = zip.entries();
                while (iter.hasMoreElements()) {
                    ZipEntry entry = iter.nextElement();
                    raw.add(new EntryData(entry.getName(), read(zip.getInputStream(entry))));
                    names.add(entry.getName());
                }
            }
            Set<String> titleFontIds = collectTitleFontIds(raw);
            List<EntryData> entries = new ArrayList<>();
            Set<String> addedFonts = new HashSet<>();
            boolean changed = false;
            for (EntryData entry : raw) {
                byte[] data = entry.data();
                if (entry.name().endsWith(".xml")) {
                    PatchedXml patched = patchXml(
                            entry.name(), data, names, titleFontIds);
                    if (patched != null) {
                        data = patched.bytes();
                        if (addedFonts.add(patched.fontEntry())) {
                            entries.add(new EntryData(patched.fontEntry(), fontBytes));
                        }
                        changed = true;
                    }
                }
                entries.add(new EntryData(entry.name(), data));
            }
            if (!changed) {
                Files.deleteIfExists(target);
                return source;
            }
            Map<String, byte[]> unique = new HashMap<>();
            for (EntryData entry : entries) {
                unique.putIfAbsent(entry.name(), entry.data());
            }
            try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(target))) {
                for (Map.Entry<String, byte[]> entry : unique.entrySet()) {
                    out.putNextEntry(new ZipEntry(entry.getKey()));
                    out.write(entry.getValue());
                    out.closeEntry();
                }
            }
            return target;
        } catch (Throwable error) {
            System.err.println("OFD fallback font patch skipped: " + error);
            if (target != null) {
                try {
                    Files.deleteIfExists(target);
                } catch (Exception ignored) {
                    // 临时文件清理失败不影响转换
                }
            }
            return source;
        }
    }

    private static PatchedXml patchXml(
            String entryName, byte[] data, Set<String> names, Set<String> titleFontIds) {
        try {
            Document document = parse(data);
            NodeList fonts = document.getElementsByTagNameNS(OFD_NS, "Font");
            if (fonts.getLength() == 0) {
                return null;
            }
            Element res = findAncestor((Element) fonts.item(0), "Res");
            if (res == null) {
                return null;
            }
            String baseLoc = res.getAttribute("BaseLoc");
            String baseDir = resolveBaseDir(entryName, baseLoc);
            String fontEntry = baseDir.isEmpty()
                    ? FALLBACK_FILE_NAME
                    : baseDir + "/" + FALLBACK_FILE_NAME;
            boolean changed = false;
            for (int index = 0; index < fonts.getLength(); index++) {
                Element font = (Element) fonts.item(index);
                String id = font.getAttribute("ID");
                if ((!titleFontIds.contains(id) && !looksLikeTitleFont(font))
                        || hasUsableFontFile(font, baseDir, names)) {
                    continue;
                }
                setFontFile(document, font, FALLBACK_FILE_NAME);
                changed = true;
            }
            if (!changed) {
                return null;
            }
            return new PatchedXml(serialize(document), fontEntry);
        } catch (Exception error) {
            return null;
        }
    }

    /**
     * 从页面文字里找出标题、红头用到的字体资源 ID。
     *
     * <p>字号明显大于正文，或者文字颜色是红色，就认为属于标题/红头。只看这两个特征，
     * 是为了避免正文缺字体时也被整体换成小标宋。</p>
     */
    private static Set<String> collectTitleFontIds(List<EntryData> entries) {
        Set<String> ids = new HashSet<>();
        for (EntryData entry : entries) {
            if (!entry.name().endsWith(".xml")) {
                continue;
            }
            try {
                Document document = parse(entry.data());
                NodeList texts = document.getElementsByTagNameNS(OFD_NS, "TextObject");
                for (int index = 0; index < texts.getLength(); index++) {
                    Element text = (Element) texts.item(index);
                    String fontId = text.getAttribute("Font");
                    if (fontId.isEmpty()) {
                        continue;
                    }
                    if (isLargeText(text) || isRedText(text)) {
                        ids.add(fontId);
                    }
                }
            } catch (Exception ignored) {
                // 单个 XML 解析失败不影响其它页面
            }
        }
        return ids;
    }

    private static boolean isLargeText(Element text) {
        String value = text.getAttribute("Size");
        if (value.isEmpty()) {
            return false;
        }
        try {
            return Double.parseDouble(value) >= TITLE_MIN_SIZE_MM;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private static boolean isRedText(Element text) {
        return isRedColor(text, "FillColor") || isRedColor(text, "StrokeColor");
    }

    private static boolean isRedColor(Element text, String localName) {
        NodeList colors = text.getElementsByTagNameNS(OFD_NS, localName);
        for (int index = 0; index < colors.getLength(); index++) {
            Element color = (Element) colors.item(index);
            String[] parts = color.getAttribute("Value").trim().split("\\s+");
            if (parts.length < 3) {
                continue;
            }
            try {
                int red = Integer.parseInt(parts[0]);
                int green = Integer.parseInt(parts[1]);
                int blue = Integer.parseInt(parts[2]);
                if (red >= 150 && green <= 120 && blue <= 120) {
                    return true;
                }
            } catch (NumberFormatException ignored) {
                // OFD 颜色值格式不标准时跳过，不影响其它文字
            }
        }
        return false;
    }

    private static boolean looksLikeTitleFont(Element font) {
        String name = (font.getAttribute("FontName") + " "
                + font.getAttribute("FamilyName")).toLowerCase();
        return name.contains("小标宋") || name.contains("大标宋")
                || name.contains("fzxiaobiao") || name.contains("fzxbs")
                || name.contains("标题");
    }

    private static boolean hasUsableFontFile(Element font, String baseDir, Set<String> names) {
        NodeList children = font.getChildNodes();
        for (int index = 0; index < children.getLength(); index++) {
            Node node = children.item(index);
            if (node instanceof Element child
                    && "FontFile".equals(child.getLocalName())) {
                String value = child.getTextContent().trim();
                if (value.isEmpty()) {
                    return false;
                }
                String path = value.startsWith("/") ? value.substring(1)
                        : (baseDir.isEmpty() ? value : baseDir + "/" + value);
                return names.contains(normalize(path));
            }
        }
        return false;
    }

    private static void setFontFile(Document document, Element font, String value) {
        NodeList children = font.getChildNodes();
        for (int index = 0; index < children.getLength(); index++) {
            Node node = children.item(index);
            if (node instanceof Element child
                    && "FontFile".equals(child.getLocalName())) {
                child.setTextContent(value);
                return;
            }
        }
        String prefix = font.getPrefix();
        Element fontFile = document.createElementNS(
                font.getNamespaceURI(), prefix == null ? "FontFile" : prefix + ":FontFile");
        fontFile.setTextContent(value);
        font.appendChild(fontFile);
    }

    private static Element findAncestor(Element element, String localName) {
        Node node = element.getParentNode();
        while (node instanceof Element parent) {
            if (localName.equals(parent.getLocalName())) {
                return parent;
            }
            node = parent.getParentNode();
        }
        return null;
    }

    private static String resolveBaseDir(String entryName, String baseLoc) {
        int slash = entryName.lastIndexOf('/');
        String parent = slash < 0 ? "" : entryName.substring(0, slash);
        if (baseLoc == null || baseLoc.isBlank()) {
            return parent;
        }
        if (baseLoc.startsWith("/")) {
            return normalize(baseLoc.substring(1));
        }
        return normalize(parent.isEmpty() ? baseLoc : parent + "/" + baseLoc);
    }

    private static String normalize(String path) {
        List<String> parts = new ArrayList<>();
        for (String part : path.split("/")) {
            if (part.isEmpty() || ".".equals(part)) {
                continue;
            }
            if ("..".equals(part)) {
                if (!parts.isEmpty()) {
                    parts.remove(parts.size() - 1);
                }
            } else {
                parts.add(part);
            }
        }
        return String.join("/", parts);
    }

    private static Document parse(byte[] data) throws Exception {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        factory.setExpandEntityReferences(false);
        return factory.newDocumentBuilder().parse(new ByteArrayInputStream(data));
    }

    private static byte[] serialize(Document document) throws Exception {
        TransformerFactory factory = TransformerFactory.newInstance();
        factory.setFeature("http://javax.xml.XMLConstants/feature/secure-processing", true);
        Transformer transformer = factory.newTransformer();
        transformer.setOutputProperty(OutputKeys.ENCODING, "UTF-8");
        transformer.setOutputProperty(OutputKeys.INDENT, "no");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        transformer.transform(new DOMSource(document), new StreamResult(output));
        return output.toByteArray();
    }

    private static byte[] read(InputStream input) throws Exception {
        try (InputStream stream = input) {
            return stream.readAllBytes();
        }
    }

    private record PatchedXml(byte[] bytes, String fontEntry) {
    }

    private record EntryData(String name, byte[] data) {
    }
}
