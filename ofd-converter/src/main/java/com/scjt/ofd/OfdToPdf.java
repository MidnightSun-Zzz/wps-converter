package com.scjt.ofd;

import org.ofdrw.converter.export.PDFExporter;

import java.nio.file.Path;

/**
 * OFD 转 PDF 的命令行入口，底层使用 OFDRW。
 *
 * <p>用法：{@code ofd2pdf <input.ofd> <output.pdf>}。参数不合法返回 2；
 * 转换失败返回 1，并把原因写到 stderr，方便调用方映射成转换错误。</p>
 */
public final class OfdToPdf {

    private OfdToPdf() {
    }

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("usage: ofd2pdf <input.ofd> <output.pdf>");
            System.exit(2);
        }
        Path source = Path.of(args[0]);
        Path target = Path.of(args[1]);
        Path patched = null;
        try {
            patched = OfdFontFallbackPatcher.patch(source);
            Path effectiveSource = patched == null ? source : patched;
            try (PDFExporter exporter = new PDFExporter(effectiveSource, target)) {
                exporter.export();
            }
            SealFallbackRenderer.apply(effectiveSource, target);
        } catch (Throwable error) {
            System.err.println("OFD conversion failed: " + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        } finally {
            if (patched != null && !patched.equals(source)) {
                try {
                    java.nio.file.Files.deleteIfExists(patched);
                } catch (Exception ignored) {
                    // 临时文件清理失败不影响已经完成的转换
                }
            }
        }
    }
}
