package com.scjt.ofd;

import org.ofdrw.converter.export.PDFExporter;

import java.nio.file.Path;

/**
 * Minimal OFD to PDF command line adapter over the OFDRW reference implementation.
 *
 * <p>Usage: {@code ofd2pdf <input.ofd> <output.pdf>}. Exit code 2 means invalid
 * arguments; any conversion failure exits with code 1 and writes the reason to
 * stderr so the calling service can map it to a conversion error.</p>
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
        try (PDFExporter exporter = new PDFExporter(source, target)) {
            exporter.export();
        } catch (Throwable error) {
            System.err.println("OFD conversion failed: " + error.getMessage());
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
