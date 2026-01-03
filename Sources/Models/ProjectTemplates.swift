import Foundation

struct ProjectTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String // SF Symbol name
    let content: String
}

class ProjectTemplates {
    static let all: [ProjectTemplate] = [
        ProjectTemplate(
            name: "Empty Project",
            description: "A blank canvas for your document.",
            icon: "doc.text",
            content: """
            #set page(width: auto, height: auto, margin: 1cm)
            
            = New Document
            
            Start typing here...
            """
        ),
        ProjectTemplate(
            name: "Article",
            description: "A standard article format with title and sections.",
            icon: "doc.text.fill",
            content: """
            #set page(
              paper: "a4",
              margin: (x: 2cm, y: 2.5cm),
            )
            #set text(
              font: "D-DIN",
              size: 11pt,
            )
            
            = Article Title
            
            == Introduction
            
            This is the introduction to your article.
            
            == Content
            
            Your content goes here.
            """
        ),
        ProjectTemplate(
            name: "Report",
            description: "A detailed report with table of contents.",
            icon: "book.closed.fill",
            content: """
            #set page(paper: "a4", numbering: "1")
            
            #align(center + horizon)[
              #text(size: 24pt, weight: "bold")[Report Title]
              
              #v(2em)
              
              Author Name
              
              #datetime.today().display()
            ]
            
            #pagebreak()
            
            #outline(indent: auto)
            
            #pagebreak()
            
            = Executive Summary
            
            Write your summary here.
            
            = Introduction
            
            Introduction content.
            """
        ),
        ProjectTemplate(
            name: "Resume",
            description: "A clean and professional resume layout.",
            icon: "person.text.rectangle",
            content: """
            #set page(paper: "a4", margin: 1.5cm)
            #set text(font: "D-DIN", size: 10pt)
            
            #align(center)[
              #text(size: 14pt, weight: "bold")[Your Name]
              
              email@example.com | +123 456 7890 | city, country
            ]
            
            = Experience
            
            == Job Title
            *Company Name* | 2020 - Present
            
            - Achievement 1
            - Achievement 2
            
            = Education
            
            == Degree Name
            *University Name* | 2016 - 2020
            """
        )
    ]
}
