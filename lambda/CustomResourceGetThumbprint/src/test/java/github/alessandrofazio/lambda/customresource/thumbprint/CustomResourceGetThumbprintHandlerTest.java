package github.alessandrofazio.lambda.customresource.thumbprint;

import com.amazonaws.services.lambda.runtime.events.CloudFormationCustomResourceEvent;
import org.junit.Before;
import org.junit.Test;
import org.mockito.Mockito;
import software.amazon.lambda.powertools.cloudformation.Response;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

public class CustomResourceGetThumbprintHandlerTest {
    private static final String OIDC_PROVIDER_URL = "OidcProviderUrl";
    private CustomResourceGetThumbprintHandler underTest;

    @Before
    public void setup() {
        underTest = new CustomResourceGetThumbprintHandler();
    }

    @Test
    public void shouldSuccessOnCreateWhenUrlExists() {
        String url = "https://www.google.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getResourceProperties()).thenReturn(Map.of(OIDC_PROVIDER_URL, url));
        Response actual = underTest.create(event, null);
        Response expected = Response.builder()
                .status(Response.Status.SUCCESS)
                .physicalResourceId(url)
                .noEcho(true)
                .build();

        assertEquals(expected.getPhysicalResourceId(), actual.getPhysicalResourceId());
        assertEquals(expected.getStatus(), actual.getStatus());
    }

    @Test
    public void shouldFailOnCreateWhenUrlDoesNotExist() {
        String url = "https://www.google-r-e-re-s-es-f-3--3.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getResourceProperties()).thenReturn(Map.of(OIDC_PROVIDER_URL, url));
        Response actual = underTest.create(event, null);
        Response expected = Response.failed(url);

        assertEquals(expected.getStatus(), actual.getStatus());
    }

    @Test
    public void shouldSuccessOnUpdateWhenUrlExists() {
        String oldUrl = "https://www.google.com";
        String newUrl = "https://www.amazon.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getPhysicalResourceId()).thenReturn(oldUrl);
        Mockito.when(event.getResourceProperties()).thenReturn(Map.of(OIDC_PROVIDER_URL, newUrl));
        Response actual = underTest.update(event, null);
        Response expected = Response.builder()
                .status(Response.Status.SUCCESS)
                .physicalResourceId(newUrl)
                .noEcho(true)
                .build();

        assertEquals(expected.getPhysicalResourceId(), actual.getPhysicalResourceId());
        assertEquals(expected.getStatus(), actual.getStatus());
    }

    @Test
    public void shouldFailOnUpdateWhenUrlDoesNotExist() {
        String oldUrl = "https://www.google.com";
        String newUrl = "https://www.google-r-e-re-s-es-f-3--3.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getPhysicalResourceId()).thenReturn(oldUrl);
        Mockito.when(event.getResourceProperties()).thenReturn(Map.of(OIDC_PROVIDER_URL, newUrl));
        Response actual = underTest.update(event, null);
        Response expected = Response.failed(newUrl);

        assertEquals(expected.getStatus(), actual.getStatus());
    }

    @Test
    public void shouldSuccessOnUpdateWhenUrlHasNotChanged() {
        String oldUrl = "https://www.google.com";
        String newUrl = "https://www.google.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getPhysicalResourceId()).thenReturn(oldUrl);
        Mockito.when(event.getResourceProperties()).thenReturn(Map.of(OIDC_PROVIDER_URL, newUrl));
        Response actual = underTest.update(event, null);
        Response expected = Response.success(oldUrl);

        assertEquals(expected.getPhysicalResourceId(), actual.getPhysicalResourceId());
        assertEquals(expected.getStatus(), actual.getStatus());
    }

    @Test
    public void shouldSuccessOnDeleteAnyhow() {
        String oldUrl = "https://www.google.com";
        CloudFormationCustomResourceEvent event = Mockito.mock(CloudFormationCustomResourceEvent.class);

        Mockito.when(event.getPhysicalResourceId()).thenReturn(oldUrl);
        Response actual = underTest.delete(event, null);
        Response expected = Response.success(oldUrl);

        assertEquals(expected.getPhysicalResourceId(), actual.getPhysicalResourceId());
        assertEquals(expected.getStatus(), actual.getStatus());
    }
}