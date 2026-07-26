**Take-home assessment**

The assessment is designed to evaluate how effectively you can do research and problem-solving using modern tools, while maintaining good technical practice in coding, version control, and writing.

You may use modern tools, including AI-based tools, search tools, and coding assistants. However, you are expected to exercise judgement, verify the correctness of your work, and ensure that your final submission is reproducible, understandable, and technically sound.

This assessment values both quality and speed. We are interested in how effectively you can reach a sound, well-justified solution within realistic time constraints.

## Before the test

Before the test, please prepare a git repository from a previous project that demonstrates your use of version control in practice. Please ensure that it is something you are permitted to share and that it does not contain confidential, proprietary, or sensitive material.

## Instructions

Please create a new git repository for this test before starting Task 1, and use good version control practice throughout the assessment.

Your submission should include:
- a Markdown file containing links to the pre-existing and final git repositories, with access granted to the Github user `mars-nesa-nsw`, and briefly describing the structure of the submission and how to run any code;
- a single final git repository containing the work completed during this test;
- the pre-existing repository you prepared before the test (it should be separate from the new git repository containing the test work)
- the responses to the tasks below.

If you use modern tools during the assessment, please provide the relevant chat/prompt history of the tools used through a link, exported transcript or prompt log. The purpose of this log is not to discourage tool use, but to help us assess your judgement, workflow, and verification practices.

**Timely submission** is part of the assessment. Please submit as soon as you have completed the work.

## Tasks

**1.** Given the XML file `exams.xml`, create a data pipeline that translates the XML into JSONL and saves the output to a new file. In addition, transform the exams data such that it can be saved as a parquet file. Changes to the layout of the data can be made but should be justified, and there should be no loss of data in the transformation process. The JSONL and parquet outputs may use different layouts, but they must preserve every student, course, school, exam, mark, and the relationships between them. Please note that the XML file contains nested records that need to be handled carefully. For example, some students attend more than one school, and some courses have more than one exam. Write your code with performance in mind, assuming that it will need to cope with production-scale datasets that are many gigabytes in size. Your final outputs should be named as `exams.jsonl` and `exams.parquet` files and be accompanied by a markdown file that explains your work. Discuss in the markdown file your methodology and performance optimizations for scalability.

**2.** Sometimes students might miss an exam paper due to valid reasons including illness and misadventure. If a resit is not available, the missing marks might need to be imputed. Consider the hypothetical student marks in `marks.csv`. Each row denotes one student and the columns are their marks in various exam papers. Develop or implement an algorithm to impute the missing integer values (labelled `M`) and output a new CSV file `marks_imputed.csv`. The header for each column specifies the weighting of each paper in a course. Each paper column is named `<SUBJECT>-<WEIGHT>`, where the weight is both the paper weighting and the maximum mark for that paper. For example, ENG-10 is marked out of 10 and ENG-90 is marked out of 90; together they sum to 100 for English. Keep in mind that only the `M` values need to be imputed, other blanks in the CSV occur when students are not registered for those courses. Furthermore, include a markdown file explaining your algorithm and the design choices you made. 

## What we will be looking for

We will assess:
- correctness and depth of reasoning;
- quality and clarity of code;
- reproducibility and organisation of the submission;
- use of version control in a thoughtful and professional manner;
- quality of written communication;
- your ability to use modern tools effectively while maintaining critical judgement;
- your ability to work efficiently and make strong progress within a limited time.