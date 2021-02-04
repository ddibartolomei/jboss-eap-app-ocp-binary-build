package com.redhat.ocp.eap;

import javax.inject.Inject;
import javax.ws.rs.GET;
import javax.ws.rs.POST;
import javax.ws.rs.Path;
import javax.ws.rs.PathParam;
import javax.ws.rs.Produces;
import java.io.FileWriter;
import java.io.PrintWriter;

@Path("/")
public class HelloController {
    @Inject
    HelloService helloService;

    @GET
    @Path("/person/{name}")
    @Produces({ "application/json" })
    public String getHelloJSON(@PathParam("name") String name) {
        return "{\"result\":\"" + helloService.createHelloMessage(name) + "\"}";
    }

    @POST
    @Path("/logger/{textline}")
    @Produces({ "application/json" })
    public String appendToFile(@PathParam("textline") String textline) {

        String dirTemp = System.getenv().get("FS_WRITE_DIR");

        FileWriter fileWriter = null;
        PrintWriter printWriter = null;
        try {
            fileWriter = new FileWriter(dirTemp + "/testFile", true);
            printWriter = new PrintWriter(fileWriter);
            printWriter.println(textline);
            return "{\"message\":\"" + textline + "\"}";
        } catch (Exception e) {
            return "{\"error\":\"" + e.getMessage() + "\"}";
        }
        finally {
            if (printWriter!=null) {
                printWriter.close();
            }
        }
    }
}
