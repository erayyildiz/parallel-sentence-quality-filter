/*
 * To change this template, choose Tools | Templates
 * and open the template in the editor.
 */
package parallelsentenceclassifier;

import edu.berkeley.nlp.lm.ArrayEncodedNgramLanguageModel;
import edu.berkeley.nlp.lm.StupidBackoffLm;
import edu.berkeley.nlp.lm.io.LmReaders;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.UnsupportedEncodingException;
import java.util.AbstractList;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 *
 * @author Eray
 */
public class NgramScore  {
    public double score;
    public Map<String,Integer> ngrams = new HashMap<>();
    public NgramScore(String sentence)  throws UnsupportedEncodingException, FileNotFoundException, IOException {

        ArrayEncodedNgramLanguageModel lm = LmReaders.readArrayEncodedLmFromArpa("C://Users/Eray/Documents/NetBeansProjects/ParallelSentenceClassifier/big_test.arpa", false);
        this.score = lm.scoreSentence(words(sentence));
         
    }
    public static List<String> words(String sentence)
    {
        String[] tokens;
        tokens = sentence.split(" ");
        ArrayList<String> words = new ArrayList<>();
        words.addAll(Arrays.asList(tokens));
        return words;
    }
}


