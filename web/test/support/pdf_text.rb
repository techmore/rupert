# frozen_string_literal: true

# The text lines of an uncompressed Prawn PDF. Prawn writes each line as a hex string (<…> Tj) in WinAnsi encoding.
module PdfText
  def pdf_text(pdf)
    pdf.b.scan(/<([0-9a-fA-F]+)> Tj/).map { |(hex)| [hex].pack('H*').force_encoding('Windows-1252').encode('UTF-8') }.join("\n")
  end
end
