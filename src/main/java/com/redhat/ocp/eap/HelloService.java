package com.redhat.ocp.eap;

import java.util.Properties;
import java.io.FileInputStream;
import javax.inject.Inject;

public class HelloService {

    @Inject
    private PersonRepository personRepository;

    String createHelloMessage(String name) {
		try {
            String dirConf = System.getenv().get("CONFIG_DIR");
            String fileName="/settings.properties";
            Properties objProperties = new Properties();
            FileInputStream objFileInputStream = new FileInputStream(dirConf+fileName);
            objProperties.load(objFileInputStream);
            objFileInputStream.close();

            Person person = personRepository.findByName(name);

            return person!=null ? objProperties.getProperty("greeting") + " " + person.getFullName() + "!" : "Cannot say " + objProperties.getProperty("greeting");
        } 
        catch (Exception e) {
			throw new RuntimeException(e.getMessage());
		} 
    }

}
