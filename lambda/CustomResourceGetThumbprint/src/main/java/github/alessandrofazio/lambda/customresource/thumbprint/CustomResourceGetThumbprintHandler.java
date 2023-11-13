package github.alessandrofazio.lambda.customresource.thumbprint;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.events.CloudFormationCustomResourceEvent;
import com.mcmaster.utility.net.SSL;
import com.mcmaster.utility.net.objects.Thumbprints;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import software.amazon.lambda.powertools.cloudformation.AbstractCustomResourceHandler;
import software.amazon.lambda.powertools.cloudformation.Response;

import java.util.Map;
import java.util.Objects;

/**
 * Handler for requests to Lambda function.
 */
public class CustomResourceGetThumbprintHandler extends AbstractCustomResourceHandler {
    private static final Logger log = LogManager.getLogger(CustomResourceGetThumbprintHandler.class);
    private static final String OIDC_PROVIDER_URL = "OidcProviderUrl";

    @Override
    protected Response create(CloudFormationCustomResourceEvent cloudFormationCustomResourceEvent, Context context) {
        validateEvent(cloudFormationCustomResourceEvent);
        log.info("Receive valid CustomResource event from CloudFormation: {}", cloudFormationCustomResourceEvent);
        String url = (String) cloudFormationCustomResourceEvent.getResourceProperties().get(OIDC_PROVIDER_URL);
        return getResponseForUrl(url);
    }

    @Override
    protected Response update(CloudFormationCustomResourceEvent cloudFormationCustomResourceEvent, Context context) {
        validateEvent(cloudFormationCustomResourceEvent);
        log.info("Receive valid CustomResource event from CloudFormation: {}", cloudFormationCustomResourceEvent);
        String newUrl = (String) cloudFormationCustomResourceEvent.getResourceProperties().get(OIDC_PROVIDER_URL);
        String physicalResourceId = cloudFormationCustomResourceEvent.getPhysicalResourceId();

        if(!physicalResourceId.equals(newUrl)) {
            return getResponseForUrl(newUrl);
        }
        else {
            return Response.success(physicalResourceId);
        }
    }

    @Override
    protected Response delete(CloudFormationCustomResourceEvent cloudFormationCustomResourceEvent, Context context) {
        Objects.requireNonNull(cloudFormationCustomResourceEvent, "cloudFormationCustomResourceEvent cannot be null.");
        log.info("Receive valid CustomResource event from CloudFormation: {}", cloudFormationCustomResourceEvent);
        String url = cloudFormationCustomResourceEvent.getPhysicalResourceId();
        return Response.success(url);
    }

    private void validateEvent(CloudFormationCustomResourceEvent cloudFormationCustomResourceEvent) {
        Objects.requireNonNull(cloudFormationCustomResourceEvent, "cloudFormationCustomResourceEvent cannot be null.");
        Objects.requireNonNull(cloudFormationCustomResourceEvent.getResourceProperties().get(OIDC_PROVIDER_URL),
                "OidcProviderUrl cannot be null.");
    }

    private Response getResponseForUrl(String url) {
        try {
            Thumbprints thumbprints = SSL.getTumbprints(url);
            Map<String, String> responseAttrs = Map.of("sha1", thumbprints.getLast().getSha1());
            log.info("Retrieved thumbprint from provided url: {}", url);
            return Response.builder()
                    .value(responseAttrs)
                    .status(Response.Status.SUCCESS)
                    .physicalResourceId(url)
                    .noEcho(true)
                    .build();
        } catch (Exception e) {
            log.error("Unable to retrieve thumbprint from provided url: {}. Got an Exception: {}", url, e);
            return Response.failed(url);
        }
    }
}