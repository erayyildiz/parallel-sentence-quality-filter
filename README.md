# parallel-sentence-quality-filter
Turkish-Englsh parallel sentence quality filter based on text classification methods. See the paper below for more information:

Yıldız, Eray, Ahmed Cüneyd Tantuğ, and Banu Diri. "The effect of parallel corpus quality vs size in English-to-Turkish SMT." Proceedings of the Sixth International Conference on Web services and Semantic Technology (WeST 2014), Chennai. 2014.

Run the following command to evaluate a Turkish-English parallel corpus:
java -jar ParallelSentenceClassifier.jar <dictionary_file> <english_file> <turkish_file> -test <arff_file>


